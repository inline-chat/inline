import { drizzle } from "drizzle-orm/postgres-js"
import { DATABASE_URL } from "@in/server/env"
import postgres from "postgres"
import * as schema from "./schema"
import { relations } from "./relations"

const DATABASE_END_TIMEOUT_SECONDS = 5

const makeQueryClient = (databaseUrl: string) =>
  postgres(databaseUrl, {
    max: 10,
    connect_timeout: 5,
    idle_timeout: 30,
    connection: {
      application_name: "inline-server",
      statement_timeout: 30_000,
      lock_timeout: 5_000,
      idle_in_transaction_session_timeout: 15_000,
    },
  })

const makeHealthQueryClient = (databaseUrl: string) =>
  postgres(databaseUrl, {
    max: 1,
    connect_timeout: 2,
    idle_timeout: 30,
    connection: {
      application_name: "inline-health",
      statement_timeout: 1_500,
      lock_timeout: 500,
      idle_in_transaction_session_timeout: 2_000,
    },
  })

let queryClient = makeQueryClient(DATABASE_URL)
let healthQueryClient =
  makeHealthQueryClient(DATABASE_URL)

export let db = drizzle(queryClient, {
  relations,
  schema,
  // logger: {
  //   logQuery(query, params) {
  //     console.log(query, params)
  //   },
  // },
})

export const initDb = (databaseUrl: string) => {
  // Best-effort close of existing connections (especially useful for tests that recreate DBs).
  void Promise.all([
    queryClient.end({
      timeout: DATABASE_END_TIMEOUT_SECONDS,
    }),
    healthQueryClient.end({
      timeout: DATABASE_END_TIMEOUT_SECONDS,
    }),
  ]).catch(() => {})

  queryClient = makeQueryClient(databaseUrl)
  healthQueryClient =
    makeHealthQueryClient(databaseUrl)
  db = drizzle(queryClient, {
    relations,
    schema,
  })
}

export const checkDatabaseHealth = () =>
  healthQueryClient.unsafe("SELECT 1").execute()

export const closeDb = async () => {
  await Promise.all([
    queryClient.end({
      timeout: DATABASE_END_TIMEOUT_SECONDS,
    }),
    healthQueryClient.end({
      timeout: DATABASE_END_TIMEOUT_SECONDS,
    }),
  ])
}

export { schema }
