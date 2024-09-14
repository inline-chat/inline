import { pgTable, serial, text, varchar } from "drizzle-orm/pg-core"
import { drizzle } from "drizzle-orm/postgres-js"
import { DATABASE_URL } from "@in/server/env"
import postgres from "postgres"

const queryClient = postgres(DATABASE_URL)

export const db = drizzle(queryClient)
