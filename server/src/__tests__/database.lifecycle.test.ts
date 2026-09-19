import { afterEach, expect, test } from "bun:test"
import { sql } from "drizzle-orm"
import { closeDb, db } from "@in/server/db"
import postgres from "postgres"
import { cleanDatabase, setupTestDatabase, teardownTestDatabase } from "./database"

const originalUrl = process.env["DATABASE_URL"]
const originalTemplate = process.env["INLINE_TEST_DATABASE_TEMPLATE"]
const currentName = async () => (await db.execute<{ name: string }>(sql`SELECT current_database() AS name`))[0]!.name
const restore = (key: string, value: string | undefined) => {
  if (value === undefined) Reflect.deleteProperty(process.env, key)
  else process.env[key] = value
}
afterEach(async () => {
  await teardownTestDatabase()
  restore("DATABASE_URL", originalUrl)
  restore("INLINE_TEST_DATABASE_TEMPLATE", originalTemplate)
})

test("overlapping setup callers share one database until the last release", async () => {
  await Promise.all([setupTestDatabase(), setupTestDatabase()])
  const name = await currentName()
  expect(name).toMatch(/^test_db_(?:\d+|[0-9a-f]{32})_[0-9a-f]{12}$/)
  await teardownTestDatabase()
  expect(await currentName()).toBe(name)
  await teardownTestDatabase()
  expect(process.env["DATABASE_URL"]).toBe(originalUrl)
  await expect(cleanDatabase()).rejects.toThrow("Call setupTestDatabase")
})

test("setup during teardown waits for a fresh isolated database", async () => {
  await setupTestDatabase()
  const oldName = await currentName()
  await Promise.all([teardownTestDatabase(), setupTestDatabase()])
  expect(await currentName()).not.toBe(oldName)
})

test("an originally absent DATABASE_URL stays absent after teardown", async () => {
  Reflect.deleteProperty(process.env, "DATABASE_URL")
  await setupTestDatabase()
  expect(process.env["DATABASE_URL"]).toContain("test_db_")
  await teardownTestDatabase()
  expect(process.env["DATABASE_URL"]).toBeUndefined()
})

test("failed setup rejects every waiter, restores configuration and permits retry", async () => {
  process.env["INLINE_TEST_DATABASE_TEMPLATE"] = `inline_test_template_${process.pid}_${crypto.randomUUID().replaceAll("-", "")}`
  const attempts = await Promise.allSettled([setupTestDatabase(), setupTestDatabase()])
  expect(attempts.map((attempt) => attempt.status)).toEqual(["rejected", "rejected"])
  expect(process.env["DATABASE_URL"]).toBe(originalUrl)
  restore("INLINE_TEST_DATABASE_TEMPLATE", originalTemplate)
  await setupTestDatabase()
  expect(await currentName()).toMatch(/^test_db_/)
})

test("reset removes application rows but preserves applied migration history", async () => {
  await setupTestDatabase()
  const before = await db.execute(sql`SELECT hash FROM drizzle._migrations ORDER BY id`)
  expect(before.length).toBeGreaterThan(0)
  await db.execute(sql`INSERT INTO users (email) VALUES ('reset@example.test')`)
  await cleanDatabase()
  expect(await db.execute(sql`SELECT email FROM users`)).toHaveLength(0)
  expect(await db.execute(sql`SELECT hash FROM drizzle._migrations ORDER BY id`)).toEqual(before)
})

test("teardown errors fail the run and still restore the caller configuration", async () => {
  await setupTestDatabase()
  const name = await currentName()
  expect(name).toMatch(/^test_db_(?:\d+|[0-9a-f]{32})_[0-9a-f]{12}$/)
  await closeDb()
  const url = new URL(process.env["TEST_DATABASE_URL"]!)
  url.pathname = "/postgres"
  const admin = postgres(url.toString(), { max: 1, connect_timeout: 5 })
  try {
    // This is our own disposable database. Removing it early induces a real
    // cleanup failure and proves teardown cannot hide it behind a green run.
    await admin.unsafe(`DROP DATABASE "${name}" WITH (FORCE)`)
  } finally { await admin.end({ timeout: 5 }) }
  await expect(teardownTestDatabase()).rejects.toThrow("Test database cleanup failed.")
  expect(process.env["DATABASE_URL"]).toBe(originalUrl)
})
