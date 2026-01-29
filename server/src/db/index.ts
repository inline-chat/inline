import { drizzle } from "drizzle-orm/postgres-js"
import postgres from "postgres"
import * as schema from "./schema"
import { relations } from "./relations"

let queryClient: postgres.Sql | undefined
let initializedDb: ReturnType<typeof drizzle> | undefined

const getDb = () => {
  if (!initializedDb) {
    const databaseUrl = process.env["DATABASE_URL"] as string
    queryClient = postgres(databaseUrl)
    initializedDb = drizzle(queryClient, {
      relations,
      schema,
      // logger: {
      //   logQuery(query, params) {
      //     console.log(query, params)
      //   },
      // },
    })
  }
  return initializedDb
}

export const db = new Proxy({} as ReturnType<typeof drizzle>, {
  get(_target, prop) {
    return getDb()[prop as keyof ReturnType<typeof drizzle>]
  },
})

export { schema }
