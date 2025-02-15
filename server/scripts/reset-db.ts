import { migrate } from "drizzle-orm/postgres-js/migrator"
import { drizzle } from "drizzle-orm/postgres-js"
import postgres from "postgres"
import { DATABASE_URL } from "../src/env"
import { resolve } from "path"
import { sql } from "drizzle-orm"

if (process.env.NODE_ENV === "production" || process.env.CI) {
  console.error("Not for production")
  process.exit(1)
}

try {
  const client = postgres(DATABASE_URL, { max: 1, database: "postgres" })
  let db = drizzle(client)

  await db.execute(sql`DROP DATABASE IF EXISTS inline_dev `)
  await db.execute(sql`CREATE DATABASE inline_dev`)
  console.info("🚧 Successfully reset db")
  client.end({ timeout: 5_000 })
} catch (error) {
  console.error("🔥 Error", error)
  process.exit(1)
}

// ??? Don't forget to close the connection, otherwise the script will hang
