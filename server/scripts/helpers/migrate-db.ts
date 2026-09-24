import postgres from "postgres"
import { migrate } from "drizzle-orm/postgres-js/migrator"
import { drizzle } from "drizzle-orm/postgres-js"
import { directDatabaseUrl, QUERY_TIMEOUTS } from "../../src/db/connectionPolicy"
import {
  appliedMigrations,
  assertMigrationLedger,
  migrationFolder,
  sourceMigrations,
} from "../../src/db/migrationState"

// One global lock for this database's Inline schema. The lock, ledger checks,
// and DDL must share a transaction: a lost lock connection cannot leave a
// second connection applying migrations without ownership.
const MIGRATION_LOCK_KEY = 0x496e6c696e65

export const migrateDb = async () => {
  const databaseUrl = directDatabaseUrl(process.env)

  const migrationClient = postgres(databaseUrl, {
    max: 1,
    connect_timeout: 5,
    // DDL must obey the same bounded lock and statement budgets as the API.
    // The migrator uses the direct endpoint, so these settings do not rely on
    // PgBouncer session semantics.
    connection: { application_name: "inline-migrator", ...QUERY_TIMEOUTS },
  })
  try {
    await migrationClient.begin(async (transaction) => {
      const lock = await transaction`
        select pg_try_advisory_xact_lock(${MIGRATION_LOCK_KEY}::bigint) as acquired
      `
      if (!lock[0]?.["acquired"]) throw new Error("Another database migration is already running.")

      const source = sourceMigrations()
      assertMigrationLedger(source, await appliedMigrations(transaction, true), "preflight")
      // postgres.js transaction handles expose savepoint, not begin/options at
      // runtime. Adapt Drizzle's nested transaction to this same connection.
      const client = Object.assign(transaction, {
        options: migrationClient.options,
        begin: transaction.savepoint,
      })
      await migrate(drizzle(client), {
        migrationsFolder: migrationFolder(),
        migrationsTable: "_migrations",
      })
      assertMigrationLedger(source, await appliedMigrations(transaction), "current")
    })
  } finally {
    await migrationClient.end({ timeout: 5 })
  }
}
