import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import postgres from "postgres"
import { appliedMigrations } from "../../src/db/migrationState"

export interface OnlineIndex {
  /** Journal tag of the migration that verifies this index and must find it built. */
  readonly migration: string
  readonly name: string
  /** One `CREATE INDEX CONCURRENTLY IF NOT EXISTS` statement. */
  readonly sql: string
}

// Indexes on large live tables cannot be built inside the migration
// transaction without blocking writes for the whole build. The migrator builds
// them CONCURRENTLY first, and only while their migration is still pending.
// That migration then checks the exact definition.
export const ONLINE_INDEXES: readonly OnlineIndex[] = [
  {
    migration: "0176_global-message-search",
    name: "messages_chat_search_date_idx",
    sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "messages_chat_search_date_idx" ON "messages" USING btree ("chat_id","date" DESC NULLS LAST,"global_id" DESC NULLS LAST)`,
  },
  {
    migration: "0176_global-message-search",
    name: "messages_document_id_idx",
    sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "messages_document_id_idx" ON "messages" USING btree ("document_id") WHERE "messages"."document_id" is not null`,
  },
]

// A concurrent build waits for older transactions. API statements and idle
// transactions are capped at 30 s and 15 s, so a minute of lock wait is enough.
// Waiting here does not block reads or writes on the table.
const ONLINE_INDEX_TIMEOUTS = {
  statement_timeout: 10 * 60_000,
  lock_timeout: 60_000,
  idle_in_transaction_session_timeout: 15_000,
}

const UNDEFINED_TABLE = "42P01"
const UNDEFINED_COLUMN = "42703"

const journalTimes = (folder: string): Map<string, number> => {
  const journal = JSON.parse(readFileSync(resolve(folder, "meta/_journal.json"), "utf8")) as {
    entries: { tag: string; when: number }[]
  }
  return new Map(journal.entries.map((entry) => [entry.tag, entry.when]))
}

/**
 * Builds the online indexes of pending migrations before the migration
 * transaction. It holds the migration advisory lock at session level, so it
 * cannot overlap another migrator. Returns the names it built.
 */
export const prebuildOnlineIndexes = async (
  databaseUrl: string,
  folder: string,
  lockKey: number,
  indexes: readonly OnlineIndex[] = ONLINE_INDEXES,
): Promise<string[]> => {
  if (indexes.length === 0) return []
  const times = journalTimes(folder)
  const client = postgres(databaseUrl, {
    max: 1,
    connect_timeout: 5,
    onnotice: () => {},
    connection: { application_name: "inline-migrator-indexes", ...ONLINE_INDEX_TIMEOUTS },
  })
  const built: string[] = []
  try {
    const [lock] = await client`select pg_try_advisory_lock(${lockKey}::bigint) as acquired`
    if (!lock?.["acquired"]) throw new Error("Another database migration is already running.")
    try {
      const applied = new Set((await appliedMigrations(client, true)).map((record) => record.createdAt))
      for (const index of indexes) {
        const when = times.get(index.migration)
        if (when === undefined) throw new Error(`Online index ${index.name} names an unknown migration.`)
        if (applied.has(when)) continue
        // An interrupted concurrent build leaves an invalid index that IF NOT EXISTS would keep.
        const [existing] = await client<{ valid: boolean }[]>`
          select indisvalid as valid from pg_index where indexrelid = to_regclass(${`public.${index.name}`})
        `
        if (existing?.valid) continue
        if (existing) await client.unsafe(`DROP INDEX CONCURRENTLY IF EXISTS "public"."${index.name}"`)
        try {
          await client.unsafe(index.sql)
        } catch (error) {
          // An older schema without the table or column: earlier pending
          // migrations create it and the target migration builds the index itself.
          const code = (error as { code?: string }).code
          if (code === UNDEFINED_TABLE || code === UNDEFINED_COLUMN) continue
          throw error
        }
        built.push(index.name)
      }
    } finally {
      await client`select pg_advisory_unlock(${lockKey}::bigint)`
    }
  } finally {
    await client.end({ timeout: 5 })
  }
  return built
}
