import { migrateDb } from "./helpers/migrate-db"

try {
  await migrateDb()
  console.info("🚧 Migrations applied successfully")
  process.exit(0)
} catch (error) {
  console.error("🔥 Error applying migrations", error)
  process.exit(1)
}

// ??? Don't forget to close the connection, otherwise the script will hang
