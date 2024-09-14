import { migrate } from "drizzle-orm/postgres-js/migrator"
import { drizzle } from "drizzle-orm/postgres-js"
import postgres from "postgres"
import { DATABASE_URL } from "../src/env"
import { resolve } from "path"

try {
  const migrationClient = postgres(DATABASE_URL, { max: 1 })

  // This will run migrations on the database, skipping the ones already applied
  await migrate(drizzle(migrationClient), {
    migrationsFolder: resolve(__dirname, "../drizzle"),
    migrationsTable: "_migrations",
  })

  console.info("🚧 Migrations applied successfully")
  migrationClient.end({ timeout: 5_000 })
} catch (error) {
  console.error("🔥 Error applying migrations", error)
}

// ??? Don't forget to close the connection, otherwise the script will hang
