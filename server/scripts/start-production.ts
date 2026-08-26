import { migrateDb } from "./helpers/migrate-db"

const artifactSmokeRequested =
  process.argv.includes(
    "--artifact-smoke",
  )
if (
  artifactSmokeRequested &&
  process.env["INLINE_SERVER_SMOKE"] !== "1"
) {
  throw new Error(
    "--artifact-smoke requires INLINE_SERVER_SMOKE=1.",
  )
}

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

// The packaged artifact must be startable in CI without production signing
// secrets. This explicit harness-only injection preserves the normal
// production entrypoint's fail-closed Inline Protocol configuration.
await runServer(
  artifactSmokeRequested
    ? {
      inlineProtocolConfiguration: {
        enabled: false,
      },
    }
    : undefined,
)
