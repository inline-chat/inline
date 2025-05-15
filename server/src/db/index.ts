import { drizzle } from "drizzle-orm/postgres-js"
import { DATABASE_URL } from "@in/server/env"
import postgres from "postgres"
import * as schema from "./schema"
import { relations } from "./relations"
const queryClient = postgres(DATABASE_URL)

export const db = drizzle(queryClient, {
  relations,
  schema,
})

export { schema }
