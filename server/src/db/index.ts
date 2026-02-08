import { drizzle } from "drizzle-orm/postgres-js"
import { DATABASE_URL } from "@in/server/env"
import postgres from "postgres"
import * as schema from "./schema"
import { relations } from "./relations"

let queryClient = postgres(DATABASE_URL)

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
  void queryClient.end({ timeout: 5_000 }).catch(() => {})

  queryClient = postgres(databaseUrl)
  db = drizzle(queryClient, {
    relations,
    schema,
  })
}

export const closeDb = async () => {
  await queryClient.end({ timeout: 5_000 })
}

export { schema }
