import { existsSync } from "node:fs"
import { resolve } from "node:path"
import { readMigrationFiles } from "drizzle-orm/migrator"
import type postgres from "postgres"

export class MigrationStateError extends Error {}

export interface MigrationRecord {
  readonly hash: string
  readonly createdAt: number
}

// Commit 84eb35373 created these indexes in an unshipped local branch at a
// timestamp just before public `0150_space-profiles`. Applying this image to a
// database carrying that record would reapply the public 0150 and then fail on
// the duplicate index names in 0151. The public 0150 has a distinct timestamp
// and remains a supported starting point for the forward 0151 migration.
const SUPERSEDED_LOCAL_INDEX_MIGRATION = {
  createdAt: 1790118615970,
  hash: "a160f2c1cf8f2abee0ad4e0e8b5988ad388904ab92abfc5614d0bf69b5f99ccc",
} as const

type AppliedMigrationRow = { hash: string; created_at: string | number }
type MigrationHeadRow = {
  required_hash: string | null
  latest_created_at: string | number | null
}

export const migrationFolder = (): string => {
  for (const folder of [resolve(process.cwd(), "server/drizzle"), resolve(process.cwd(), "drizzle")]) {
    if (existsSync(resolve(folder, "meta/_journal.json"))) return folder
  }
  throw new MigrationStateError("The packaged migration journal is missing.")
}

export const sourceMigrations = (folder = migrationFolder()): MigrationRecord[] => {
  const records = readMigrationFiles({ migrationsFolder: folder }).map((entry) => ({
    hash: entry.hash,
    createdAt: entry.folderMillis,
  }))
  if (
    records.length === 0 ||
    records.some(
      (record, index) =>
        !Number.isSafeInteger(record.createdAt) || (index > 0 && record.createdAt <= records[index - 1]!.createdAt),
    )
  ) {
    throw new MigrationStateError("The packaged migration journal is empty or unordered.")
  }
  return records
}

/** Historical ledgers may include retired branch migrations absent from this image. */
export const assertMigrationLedger = (
  source: readonly MigrationRecord[],
  applied: readonly MigrationRecord[],
  mode: "startup" | "preflight" | "current",
): void => {
  if (source.length === 0) throw new MigrationStateError("The packaged migration journal is empty.")
  if (
    applied.some(
      (record, index) =>
        !Number.isSafeInteger(record.createdAt) || (index > 0 && record.createdAt <= applied[index - 1]!.createdAt),
    )
  ) {
    throw new MigrationStateError("The database migration history is unordered or duplicated.")
  }
  if (applied.some((record) => record.createdAt === SUPERSEDED_LOCAL_INDEX_MIGRATION.createdAt)) {
    throw new MigrationStateError(
      "The database contains the superseded local 0150 index migration; it requires a reviewed reconciliation before this image can migrate or serve it.",
    )
  }
  const latestApplied = applied.at(-1)?.createdAt ?? -Infinity
  if (latestApplied > source.at(-1)!.createdAt && mode !== "startup") {
    throw new MigrationStateError("The database is ahead of this migration command.")
  }
  const byTime = new Map(applied.map((record) => [record.createdAt, record.hash]))
  for (const record of source) {
    if (!byTime.has(record.createdAt)) {
      if (record.createdAt <= latestApplied) {
        throw new MigrationStateError("A required migration is missing before the database head.")
      }
      if (mode !== "preflight") {
        throw new MigrationStateError("The database is behind the server's required migration.")
      }
    }
  }
  // Older SQL files changed across previous Inline branches even though their
  // timestamped ledger entries remain. The active head hash is authoritative.
  const knownHead = source.findLast((record) => record.createdAt <= latestApplied)
  if (knownHead && byTime.get(knownHead.createdAt) !== knownHead.hash) {
    throw new MigrationStateError("The database migration head differs from the packaged migration.")
  }
}

export const appliedMigrations = async (
  client: postgres.Sql,
  allowEmptyDatabase = false,
): Promise<MigrationRecord[]> => {
  if (allowEmptyDatabase) {
    // A caught undefined-table error still aborts a PostgreSQL transaction.
    // Check existence without an error so a fresh database can be migrated.
    const [row] = await client<{ ledger: string | null }[]>`select to_regclass('drizzle._migrations') as ledger`
    if (!row?.ledger) return []
  }
  const rows = await client
    .unsafe<AppliedMigrationRow[]>("select hash, created_at from drizzle._migrations order by created_at, id")
    .execute()
  return rows.map((row) => ({ hash: row.hash, createdAt: Number(row.created_at) }))
}

export const validateAppliedMigrations = async (client: postgres.Sql): Promise<void> => {
  const source = sourceMigrations()
  const applied = await appliedMigrations(client)
  assertMigrationLedger(source, applied, "startup")
}

let requiredMigration: MigrationRecord | undefined

export const assertMigrationHead = (required: MigrationRecord, row: MigrationHeadRow | undefined): void => {
  if (
    row?.required_hash !== required.hash ||
    !Number.isSafeInteger(Number(row.latest_created_at)) ||
    Number(row.latest_created_at) < required.createdAt
  ) {
    throw new MigrationStateError("The database is behind or differs from the required migration.")
  }
}

/** Small read on readiness, so a restored older database cannot remain routable. */
export const checkMigrationHead = (client: postgres.Sql) => {
  requiredMigration ??= sourceMigrations().at(-1)!
  const required = requiredMigration
  const query = client
    .unsafe<MigrationHeadRow[]>(
      `select
      (select hash from drizzle._migrations where created_at = $1 order by id desc limit 1) as required_hash,
      (select max(created_at) from drizzle._migrations) as latest_created_at`,
      [required.createdAt],
    )
    .execute()
  return Object.assign(
    query.then(([row]) => assertMigrationHead(required, row)),
    {
      cancel: () => query.cancel(),
    },
  )
}
