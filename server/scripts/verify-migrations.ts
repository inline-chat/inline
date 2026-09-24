import postgres from "postgres"
import { directDatabaseUrl, HEALTH_TIMEOUTS } from "../src/db/connectionPolicy"
import { MigrationStateError, sourceMigrations, validateAppliedMigrations } from "../src/db/migrationState"

export async function main(): Promise<number> {
  if (process.argv.includes("--help")) {
    console.info("Usage: bun server/dist/verify-migrations.js (read-only direct database check)")
    return 0
  }
  if (process.argv.length > 2) {
    console.error("Unexpected arguments. Use --help for usage.")
    return 2
  }
  let client: ReturnType<typeof postgres> | undefined
  try {
    client = postgres(directDatabaseUrl(process.env), {
      max: 1,
      connect_timeout: 5,
      connection: { application_name: "inline-migration-verify", ...HEALTH_TIMEOUTS },
    })
    await validateAppliedMigrations(client)
    console.info(`Database migration gate passed: ${sourceMigrations().at(-1)!.createdAt}`)
    return 0
  } catch (error) {
    console.error(
      error instanceof MigrationStateError ? error.message : "Database migration ledger could not be checked.",
    )
    return 1
  } finally {
    await client?.end({ timeout: 5 })
  }
}

if (import.meta.main) process.exitCode = await main()
