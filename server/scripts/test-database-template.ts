import { randomUUID } from "node:crypto"
import { resolve } from "node:path"
import { drizzle } from "drizzle-orm/postgres-js"
import { migrate } from "drizzle-orm/postgres-js/migrator"
import postgres from "postgres"

const TEMPLATE_DATABASE_PREFIX = "inline_test_template_"
const LOCAL_DATABASE_HOSTS = new Set(["localhost", "127.0.0.1"])

type TestDatabaseTemplate = {
  name: string
  dispose: () => Promise<void>
}

const databaseUrl = (
  baseUrl: string,
  databaseName: string,
): string => {
  const parsed = new URL(baseUrl)
  parsed.pathname = `/${databaseName}`
  return parsed.toString()
}

const quoteIdentifier = (value: string): string =>
  `"${value.replaceAll('"', '""')}"`

export const assertLocalTestDatabaseUrl = (
  provisioningUrl: string,
): void => {
  let parsed: URL
  try { parsed = new URL(provisioningUrl) } catch { throw new Error("Invalid test database URL.") }
  if (!["postgres:", "postgresql:"].includes(parsed.protocol) || parsed.search || parsed.hash) {
    throw new Error("Test database URL must be PostgreSQL with no query overrides or fragment.")
  }
  if (!LOCAL_DATABASE_HOSTS.has(parsed.hostname)) {
    throw new Error(
      `Refusing to run DB tests against non-local host '${parsed.hostname}'.`,
    )
  }
}

const createTemplateName = (): string =>
  `${TEMPLATE_DATABASE_PREFIX}${process.pid}_${randomUUID().replaceAll("-", "")}`

const assertOwnedTemplateName = (
  name: string,
): void => {
  const expected = new RegExp(
    `^${TEMPLATE_DATABASE_PREFIX}${process.pid}_[0-9a-f]{32}$`,
  )
  if (!expected.test(name)) {
    throw new Error(
      `Refusing to dispose an unowned test database '${name}'.`,
    )
  }
}

const withAdminDatabase = async <T>(
  provisioningUrl: string,
  operation: (
    adminDb: ReturnType<typeof postgres>,
  ) => Promise<T>,
): Promise<T> => {
  const adminDb = postgres(
    databaseUrl(provisioningUrl, "postgres"),
    {
      max: 1,
      idle_timeout: 10,
      connect_timeout: 5,
      onnotice: () => {},
    },
  )
  try {
    return await operation(adminDb)
  } finally {
    await adminDb.end({ timeout: 5 })
  }
}

const dropOwnedTemplateDatabase = async (
  provisioningUrl: string,
  templateName: string,
): Promise<void> => {
  assertLocalTestDatabaseUrl(provisioningUrl)
  assertOwnedTemplateName(templateName)
  await withAdminDatabase(
    provisioningUrl,
    async (adminDb) => {
      // Only this invocation's cryptographically named clones are eligible.
      // This also cleans up a worker killed before its afterAll can run.
      const prefix = `test_db_${templateName.slice(-32)}_`
      const clones = await adminDb<{ datname: string }[]>`
        SELECT datname FROM pg_database WHERE starts_with(datname, ${prefix})
      `
      const errors: unknown[] = []
      for (const database of [...clones.map((row) => row.datname), templateName]) {
        try {
          await adminDb.unsafe(`DROP DATABASE ${quoteIdentifier(database)} WITH (FORCE)`)
        } catch (error) { errors.push(error) }
      }
      if (errors.length) throw new AggregateError(errors, "Test database disposal failed.")
    },
  )
}

const migrateTemplateDatabase = async (
  templateUrl: string,
): Promise<void> => {
  const migrationDb = postgres(templateUrl, { max: 1, connect_timeout: 5, onnotice: () => {} })
  try {
    await migrate(drizzle(migrationDb), {
      migrationsFolder: resolve(import.meta.dir, "../drizzle"),
      migrationsTable: "_migrations",
    })
  } finally {
    await migrationDb.end({ timeout: 5 })
  }
}

export const prepareTestDatabaseTemplate = async (
  provisioningUrl: string,
): Promise<TestDatabaseTemplate> => {
  assertLocalTestDatabaseUrl(provisioningUrl)

  const name = createTemplateName()
  const templateUrl = databaseUrl(provisioningUrl, name)
  let created = false

  try {
    await withAdminDatabase(
      provisioningUrl,
      async (adminDb) => {
        await adminDb.unsafe(
          `CREATE DATABASE ${quoteIdentifier(name)}`,
        )
        created = true
      },
    )
    await migrateTemplateDatabase(templateUrl)
  } catch (error) {
    if (created) {
      try {
        await dropOwnedTemplateDatabase(provisioningUrl, name)
      } catch (cleanupError) {
        throw new AggregateError(
          [error, cleanupError],
          "Test database template setup failed and cleanup could not remove it.",
        )
      }
    }
    throw error
  }

  let disposePromise: Promise<void> | undefined
  return {
    name,
    dispose: async () => {
      disposePromise ??= dropOwnedTemplateDatabase(
        provisioningUrl,
        name,
      )
      await disposePromise
    },
  }
}
