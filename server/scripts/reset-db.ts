import postgres from "postgres"
import { migrateDb } from "./helpers/migrate-db"

const DEVELOPMENT_DATABASE_NAME = "inline_dev"
const LOCAL_DATABASE_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"])

type ResetEnvironment = {
  nodeEnv?: string
  ci?: string
}

export const validateDevelopmentResetTarget = (
  databaseUrl: string | undefined,
  environment: ResetEnvironment = {
    nodeEnv: process.env.NODE_ENV,
    ci: process.env["CI"],
  },
) => {
  if (environment.nodeEnv === "production" || environment.ci) {
    throw new Error("Refusing to reset a database in production or CI.")
  }
  if (!databaseUrl) {
    throw new Error("DATABASE_URL is not defined.")
  }

  let parsed: URL
  try {
    parsed = new URL(databaseUrl)
  } catch {
    throw new Error("DATABASE_URL must be a valid URL.")
  }

  if (parsed.protocol !== "postgres:" && parsed.protocol !== "postgresql:") {
    throw new Error("DATABASE_URL must use the postgres or postgresql protocol.")
  }

  if (!LOCAL_DATABASE_HOSTS.has(parsed.hostname)) {
    throw new Error(
      `Refusing to reset a database on non-local host '${parsed.hostname}'.`,
    )
  }

  const databaseName = decodeURIComponent(parsed.pathname.slice(1))
  if (databaseName !== DEVELOPMENT_DATABASE_NAME) {
    throw new Error(
      `Refusing to reset database '${databaseName || "(missing)"}'; expected '${DEVELOPMENT_DATABASE_NAME}'.`,
    )
  }

  return databaseUrl
}

export const resetDevelopmentDatabase = async () => {
  const databaseUrl = validateDevelopmentResetTarget(
    process.env["DATABASE_URL"],
  )
  const client = postgres(databaseUrl, {
    max: 1,
    database: "postgres",
  })

  try {
    await client.unsafe(
      `DROP DATABASE IF EXISTS "${DEVELOPMENT_DATABASE_NAME}" WITH (FORCE)`,
    )
    await client.unsafe(`CREATE DATABASE "${DEVELOPMENT_DATABASE_NAME}"`)
  } finally {
    await client.end({ timeout: 5 })
  }

  await migrateDb()
  console.info("🚧 Reset and migrated local inline_dev database")
}

if (import.meta.main) {
  try {
    await resetDevelopmentDatabase()
  } catch (error) {
    console.error("🔥 Error resetting local development database", error)
    process.exitCode = 1
  }
}
