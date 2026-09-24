import { randomUUID } from "node:crypto"
import { afterAll, beforeAll, beforeEach } from "bun:test"
import { sql } from "drizzle-orm"
import postgres from "postgres"
import { migrateDb } from "../../scripts/helpers/migrate-db"
import { assertLocalTestDatabaseUrl } from "../../scripts/test-database-template"
import { closeDb, db, initDb } from "../db"
import { waitForPostCommitHooks } from "../db/commitHooks"
import { applicationBackgroundWork } from "../lifecycle/backgroundWork"
import { outboundPublications } from "../modules/internalMessaging/outbound"
import { AccessGuardsCache } from "../modules/authorization/accessGuardsCache"
import { connectionBackgroundWork } from "../ws/backgroundWork"

type Lease = { refs: number; name: string; ready: Promise<void>; release: () => Promise<void> }
const state: { active?: Lease; teardown?: Promise<void> } = {}
const databaseUrl = (base: string, name: string) => {
  const url = new URL(base)
  url.pathname = `/${name}`
  return url.toString()
}
const withAdmin = async (base: string, operation: (client: ReturnType<typeof postgres>) => Promise<void>) => {
  const client = postgres(databaseUrl(base, "postgres"), { max: 1, connect_timeout: 5, onnotice: () => {} })
  try { await operation(client) } finally { await client.end({ timeout: 5 }) }
}
const drainDatabaseBackgroundWork = async () => {
  await applicationBackgroundWork.waitForIdle()
  await connectionBackgroundWork.waitForIdle()
  // Application work can commit a user update, whose publication must finish
  // before test teardown closes or truncates its database.
  await waitForPostCommitHooks()
  await outboundPublications.drain()
}

export const setupTestDatabase = async () => {
  if (state.teardown) await state.teardown
  if (state.active) {
    state.active.refs += 1
    return state.active.ready
  }
  const base = process.env["TEST_DATABASE_URL"] ?? process.env["DATABASE_URL"]
  if (!base) throw new Error("TEST_DATABASE_URL (or DATABASE_URL) is required to run DB tests")
  assertLocalTestDatabaseUrl(base)
  const template = process.env["INLINE_TEST_DATABASE_TEMPLATE"]
  if (template && !/^inline_test_template_[0-9]+_[0-9a-f]{32}$/.test(template)) {
    throw new Error("Invalid test database template name.")
  }
  const name = `test_db_${template?.slice(-32) ?? process.pid}_${randomUUID().replaceAll("-", "").slice(0, 12)}`
  const originalUrl = process.env["DATABASE_URL"]
  let created = false
  const release = async () => {
    const errors: unknown[] = []
    try {
      await drainDatabaseBackgroundWork()
      await closeDb()
    } catch (error) { errors.push(error) }
    try {
      if (created) await withAdmin(base, async (client) => {
        await client.unsafe(`DROP DATABASE "${name}" WITH (FORCE)`)
        created = false
      })
    } catch (error) { errors.push(error) }
    if (originalUrl === undefined) Reflect.deleteProperty(process.env, "DATABASE_URL")
    else process.env["DATABASE_URL"] = originalUrl
    if (errors.length) throw new AggregateError(errors, "Test database cleanup failed.")
  }
  const lease: Lease = { refs: 1, name, ready: Promise.resolve(), release }
  state.active = lease
  lease.ready = (async () => {
    try {
      await drainDatabaseBackgroundWork()
      await closeDb()
      await withAdmin(base, async (client) => {
        await client.unsafe(`CREATE DATABASE "${name}"${template ? ` TEMPLATE "${template}"` : ""}`)
        created = true
      })
      process.env["DATABASE_URL"] = databaseUrl(base, name)
      initDb(process.env["DATABASE_URL"])
      if (!template) await migrateDb()
    } catch (error) {
      try { await release() } catch (cleanupError) {
        throw new AggregateError([error, cleanupError], "Test database setup and cleanup failed.")
      } finally { if (state.active === lease) state.active = undefined }
      throw error
    }
  })()
  return lease.ready
}

export const teardownTestDatabase = async () => {
  if (state.teardown) return state.teardown
  const lease = state.active
  if (!lease) return
  lease.refs -= 1
  if (lease.refs > 0) return
  state.teardown = (async () => {
    // A failed setup already released its resources and surfaced its error.
    try { await lease.ready } catch { return }
    await lease.release()
  })().finally(() => {
    if (state.active === lease) state.active = undefined
    state.teardown = undefined
  })
  return state.teardown
}

export const cleanDatabase = async () => {
  const lease = state.active
  if (!lease) throw new Error("Call setupTestDatabase before cleanDatabase.")
  await lease.ready
  await drainDatabaseBackgroundWork()
  const [current] = await db.execute<{ name: string }>(sql`SELECT current_database() AS name`)
  if (current?.name !== lease.name) throw new Error("Refusing to clean a database not owned by this test lifecycle.")
  AccessGuardsCache.resetAll()
  try {
    await db.execute(sql`
      SET client_min_messages TO WARNING;
      DO $$ DECLARE
        table_list TEXT;
      BEGIN
        SELECT string_agg(
          format('%I.%I', schemaname, tablename),
          ', '
        )
        INTO table_list
        FROM pg_tables
        WHERE schemaname = 'public';

        IF table_list IS NOT NULL THEN
          EXECUTE 'TRUNCATE TABLE ' || table_list || ' CASCADE';
        END IF;
      END $$;
      SET client_min_messages TO NOTICE;
    `)
  } catch (error) {
    console.error("Failed to clean database before test:", error)
    throw error
  }
}

export const setupTestLifecycle = () => {
  beforeAll(setupTestDatabase)
  afterAll(teardownTestDatabase)
  beforeEach(cleanDatabase)
}
