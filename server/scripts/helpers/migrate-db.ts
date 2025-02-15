import { migrate } from "drizzle-orm/postgres-js/migrator"
import { drizzle } from "drizzle-orm/postgres-js"
import postgres from "postgres"
import { resolve } from "path"

const DATABASE_URL = process.env["DATABASE_URL"] as string
export const migrateDb = async () => {
  const migrationClient = postgres(DATABASE_URL, { max: 1 })

  // This will run migrations on the database, skipping the ones already applied
  await migrate(drizzle(migrationClient), {
    migrationsFolder: resolve(__dirname, "../../drizzle"),
    migrationsTable: "_migrations",
  })

  await migrationClient.end({ timeout: 5_000 })
}
