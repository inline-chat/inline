import { migrateDb } from "./helpers/migrate-db"

export async function main(): Promise<number> {
  // Imports load before --help so image checks catch missing dependencies.
  if (process.argv.includes("--help")) {
    console.info("Usage: bun server/dist/migrate.js (uses the direct database connection)")
    return 0
  }
  if (process.argv.length > 2) {
    console.error("Unexpected arguments. Use --help for usage.")
    return 2
  }
  try {
    await migrateDb()
    console.info("Migrations applied successfully")
    return 0
  } catch {
    // Database errors may contain credentials or SQL; do not log raw errors.
    console.error("Migration failed; API promotion must stop. Check the database ledger before retrying.")
    return 1
  }
}

if (import.meta.main) process.exitCode = await main()
