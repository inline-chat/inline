import postgres from "postgres"
import { migrate } from "drizzle-orm/postgres-js/migrator"
import { drizzle } from "drizzle-orm/postgres-js"
import { resolve } from "path"

export const migrateDb = async () => {
  const databaseUrl = process.env["DATABASE_URL"]
  if (!databaseUrl) {
    throw new Error("DATABASE_URL is not defined.")
  }

  const migrationClient = postgres(databaseUrl, { max: 1 })

  // This will run migrations on the database, skipping the ones already applied
  await migrate(drizzle(migrationClient), {
    migrationsFolder: resolve(__dirname, "../../drizzle"),
    migrationsTable: "_migrations",
  })

  await migrationClient.end({ timeout: 5_000 })
}
