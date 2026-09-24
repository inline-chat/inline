import { drizzle } from "drizzle-orm/postgres-js"
import { DATABASE_URL } from "@in/server/env"
import { makeDatabaseClients } from "./connectionPolicy"
import { installPostCommitHooks } from "./commitHooks"
import { checkMigrationHead, MigrationStateError, validateAppliedMigrations } from "./migrationState"
import * as schema from "./schema"
import { relations } from "./relations"

let clients = makeDatabaseClients(DATABASE_URL, process.env)

const createDatabase = (queryClient: typeof clients.queryClient) => installPostCommitHooks(drizzle(queryClient, {
  relations,
  schema,
  // logger: {
  //   logQuery(query, params) {
  //     console.log(query, params)
  //   },
  // },
}))

export let db = createDatabase(clients.queryClient)

export const initDb = (databaseUrl: string) => {
  // Best-effort close of existing connections (especially useful for tests that recreate DBs).
  const next = makeDatabaseClients(databaseUrl, process.env)
  void clients.close().catch(() => {})
  clients = next
  db = createDatabase(clients.queryClient)
}

export const checkDatabaseHealth = () => {
  const database = clients.checkHealth()
  const migrations = checkMigrationHead(clients.healthClient)
  return Object.assign(Promise.all([database, migrations]).then(([rows]) => rows), {
    cancel: () => {
      try { database.cancel?.() } finally { migrations.cancel() }
    },
  })
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
}
export const closeDb = () => clients.close()

export { schema }
