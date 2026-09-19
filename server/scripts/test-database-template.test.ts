import { randomUUID } from "node:crypto"
import { afterEach, expect, test } from "bun:test"
import postgres from "postgres"
import { prepareTestDatabaseTemplate, assertLocalTestDatabaseUrl } from "./test-database-template"

const provisioningUrl =
  process.env["TEST_DATABASE_URL"] ??
  process.env["DATABASE_URL"]!
const ownedCloneName =
  `test_db_template_regression_${process.pid}_${randomUUID().replaceAll("-", "").slice(0, 12)}`

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

const withAdminDatabase = async <T>(
  operation: (adminDb: ReturnType<typeof postgres>) => Promise<T>,
): Promise<T> => {
  const adminDb = postgres(
    databaseUrl(provisioningUrl, "postgres"),
    { max: 1 },
  )
  try {
    return await operation(adminDb)
  } finally {
    await adminDb.end({ timeout: 5 })
  }
}

const dropClone = async (): Promise<void> => {
  await withAdminDatabase(
    async (adminDb) => {
      await adminDb.unsafe(
        `DROP DATABASE IF EXISTS ${quoteIdentifier(ownedCloneName)} WITH (FORCE)`,
      )
    },
  )
}

let cloneCreated = false
afterEach(async () => { if (cloneCreated) { await dropClone(); cloneCreated = false } })

test("prepares a migrated template that can create isolated clones", async () => {
  const template = await prepareTestDatabaseTemplate(provisioningUrl)
  const abandonedClone = `test_db_${template.name.slice(-32)}_abc123abc123`
  try {
    assertLocalTestDatabaseUrl(provisioningUrl)
    await withAdminDatabase(
      async (adminDb) => {
        await adminDb.unsafe(
          `CREATE DATABASE ${quoteIdentifier(ownedCloneName)} TEMPLATE ${quoteIdentifier(template.name)}`,
        )
        cloneCreated = true
        await adminDb.unsafe(`CREATE DATABASE ${quoteIdentifier(abandonedClone)} TEMPLATE ${quoteIdentifier(template.name)}`)
      },
    )

    const cloneDb = postgres(
      databaseUrl(provisioningUrl, ownedCloneName),
      { max: 1 },
    )
    try {
      const [result] = await cloneDb<{
        users_table: string | null
        migrations_table: string | null
      }[]>`
        SELECT
          to_regclass('public.users') AS users_table,
          to_regclass('drizzle._migrations') AS migrations_table
      `
      expect(result).toEqual({
        users_table: "users",
        migrations_table: "drizzle._migrations",
      })
    } finally {
      await cloneDb.end({ timeout: 5 })
    }
  } finally {
    await template.dispose()
  }
  await withAdminDatabase(async (adminDb) => {
    const remaining = await adminDb<{ datname: string }[]>`
      SELECT datname FROM pg_database WHERE datname IN (${template.name}, ${abandonedClone}, ${ownedCloneName})
    `
    // The normal clone belongs to this test's afterEach, not template disposal.
    expect(remaining.map((row) => row.datname)).toEqual([ownedCloneName])
  })
  // Disposal is idempotent even after resources are gone.
  await template.dispose()
})

test("rejects non-local provisioning URLs before connecting", async () => {
  await expect(
    prepareTestDatabaseTemplate(
      "postgres://user@database.example.com:5432/postgres",
    ),
  ).rejects.toThrow("Refusing to run DB tests against non-local host")
})

test.each([
  "http://localhost/database", "postgres://localhost/postgres?host=remote.example",
  "postgres://localhost/postgres#fragment", "not a URL",
])("rejects invalid or overridden database URLs: %s", (url) => {
  expect(() => assertLocalTestDatabaseUrl(url)).toThrow()
})
