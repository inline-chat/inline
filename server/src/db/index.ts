import { drizzle } from "drizzle-orm/postgres-js"
import { DATABASE_URL } from "@in/server/env"
import { cachedHealthProbe, combineHealthProbes, makeDatabaseClients } from "./connectionPolicy"
import { installPostCommitHooks } from "./commitHooks"
import { checkMigrationHead, MigrationStateError, validateAppliedMigrations } from "./migrationState"
import * as schema from "./schema"
import { relations } from "./relations"
import { startDatabaseDiagnostics } from "./databaseDiagnostics"
import { Log, LogLevel } from "@in/server/utils/log"

const diagnosticsLog = new Log("db.diagnostics", LogLevel.INFO)
let stopDiagnostics: (() => void) | undefined

let clients = makeDatabaseClients(DATABASE_URL, process.env)
// The migration head only moves on deploy or restore; one read per interval
// still catches a restored older database within about a minute.
let migrationHead = cachedHealthProbe(() => checkMigrationHead(clients.healthClient))

const createDatabase = (queryClient: typeof clients.queryClient) => installPostCommitHooks(drizzle(queryClient, {
  relations,
  schema,
}))

export let db = createDatabase(clients.queryClient)

export const initDb = (databaseUrl: string) => {
  // Best-effort close of existing connections (especially useful for tests that recreate DBs).
  const next = makeDatabaseClients(databaseUrl, process.env)
  stopDiagnostics?.()
  stopDiagnostics = undefined
  void clients.close().catch(() => {})
  clients = next
  migrationHead = cachedHealthProbe(() => checkMigrationHead(clients.healthClient))
  db = createDatabase(clients.queryClient)
}

export const checkDatabaseHealth = () => {
  const database = clients.checkHealth()
  const migrations = migrationHead()
  return migrations ? combineHealthProbes(database, [migrations]) : database
}

export const validateDatabaseStartup = async () => {
  await clients.validateStartup()
  try {
    await validateAppliedMigrations(clients.healthClient)
  } catch (error) {
    // Database driver errors may contain connection metadata. Only our own
    // bounded validation messages are safe to include in production logs.
    console.error(error instanceof MigrationStateError
      ? `Database migration check failed: ${error.message}`
      : "Database migration ledger could not be checked.")
    throw error
  }
  if (!stopDiagnostics) {
    try { diagnosticsLog.info("Database connection configuration", clients.diagnosticsConfiguration) } catch { /* Best-effort. */ }
    stopDiagnostics = startDatabaseDiagnostics((row) => diagnosticsLog.info("Database operation window", row))
  }
}
export const closeDb = async () => {
  try { await clients.close() } finally {
    stopDiagnostics?.()
    stopDiagnostics = undefined
  }
}

export { schema }
