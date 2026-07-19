import { migrateDb } from "./helpers/migrate-db"

if (process.env["SKIP_DB_MIGRATIONS"] === "1") {
  console.info("Skipping database migrations")
} else {
  console.info("Running database migrations")

  try {
    await migrateDb()
    console.info("Database migrations applied successfully")
  } catch (error) {
    console.error("Error applying database migrations", error)
    process.exit(1)
  }
}

const { runServer } =
  await import(
    new URL(
      "../dist/index.js",
      import.meta.url,
    ).href
  )

await runServer()
