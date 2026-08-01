import { randomUUID } from "node:crypto"
import { afterAll, beforeAll, beforeEach } from "bun:test"
import { sql } from "drizzle-orm"
import postgres from "postgres"
import { migrateDb } from "../../scripts/helpers/migrate-db"
import { closeDb, db, initDb } from "../db"
import { AccessGuardsCache } from "../modules/authorization/accessGuardsCache"

const BASE_TEST_DB_NAME = "test_db"

type TestDatabaseState = {
  refCount: number
  setupPromise?: Promise<void>
  teardownPromise?: Promise<void>
  testDbName: string
  originalDatabaseUrl?: string
  provisioningDbUrl?: string
  testDbUrl?: string
}

const createTestDbName = () => {
  const suffix = randomUUID().replaceAll("-", "").slice(0, 12)
  return `${BASE_TEST_DB_NAME}_${process.pid}_${suffix}`
}

const getTestDatabaseState = (): TestDatabaseState => {
  const key = Symbol.for("inline.testDbState")
  const globalState = globalThis as unknown as Record<
    symbol,
    TestDatabaseState | undefined
  >

  globalState[key] ??= {
    refCount: 0,
    testDbName: createTestDbName(),
  }
  return globalState[key]
}

const localDatabaseUrl = (): string => {
  const value =
    process.env["TEST_DATABASE_URL"] ??
    process.env["DATABASE_URL"]
  if (!value) {
    throw new Error(
      "TEST_DATABASE_URL (or DATABASE_URL) is required to run DB tests",
    )
  }

  const parsed = new URL(value)
  if (
    parsed.hostname !== "localhost" &&
    parsed.hostname !== "127.0.0.1"
  ) {
    throw new Error(
      `Refusing to run DB tests against non-local host '${parsed.hostname}'.`,
    )
  }
  return value
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

const withAdminDatabase = async (
  provisioningDbUrl: string,
  operation: (adminDb: ReturnType<typeof postgres>) => Promise<void>,
) => {
  const adminDb = postgres(
    databaseUrl(provisioningDbUrl, "postgres"),
    {
      max: 1,
      idle_timeout: 10,
    },
  )
  try {
    await operation(adminDb)
  } finally {
    await adminDb.end()
  }
}

const dropTestDatabase = async (
  provisioningDbUrl: string,
  testDbName: string,
) =>
  await withAdminDatabase(
    provisioningDbUrl,
    async (adminDb) => {
      await adminDb.unsafe(
        `DROP DATABASE IF EXISTS ${quoteIdentifier(testDbName)} WITH (FORCE)`,
      )
    },
  )

export const setupTestDatabase = async () => {
  const state = getTestDatabaseState()
  state.refCount += 1

  if (state.setupPromise) {
    return await state.setupPromise
  }

  state.setupPromise = (async () => {
    const provisioningDbUrl = localDatabaseUrl()
    state.originalDatabaseUrl = process.env["DATABASE_URL"]
    state.provisioningDbUrl = provisioningDbUrl
    state.testDbUrl = databaseUrl(
      provisioningDbUrl,
      state.testDbName,
    )

    await closeDb().catch(() => {})

    await withAdminDatabase(
      provisioningDbUrl,
      async (adminDb) => {
        await adminDb.unsafe(
          `CREATE DATABASE ${quoteIdentifier(state.testDbName)}`,
        )
      },
    )

    process.env["DATABASE_URL"] = state.testDbUrl
    initDb(state.testDbUrl)
    await migrateDb()
  })()

  try {
    await state.setupPromise
  } catch (error) {
    await closeDb().catch(() => {})
    if (state.provisioningDbUrl) {
      await dropTestDatabase(
        state.provisioningDbUrl,
        state.testDbName,
      ).catch(() => {})
    }
    state.setupPromise = undefined
    state.refCount = Math.max(0, state.refCount - 1)
    console.error("Test database setup failed:", error)
    throw error
  }
}

export const teardownTestDatabase = async () => {
  const state = getTestDatabaseState()
  state.refCount = Math.max(0, state.refCount - 1)

  if (state.refCount > 0) {
    return
  }
  if (state.teardownPromise) {
    return await state.teardownPromise
  }

  state.teardownPromise = (async () => {
    try {
      await closeDb().catch(() => {})

      if (state.provisioningDbUrl) {
        await dropTestDatabase(
          state.provisioningDbUrl,
          state.testDbName,
        )
      }

      const restoreUrl =
        state.originalDatabaseUrl ??
        state.provisioningDbUrl
      if (!restoreUrl) {
        throw new Error(
          "Test database teardown lost its provisioning URL.",
        )
      }
      process.env["DATABASE_URL"] = restoreUrl
    } catch (error) {
      console.error("Test cleanup failed:", error)
    } finally {
      state.setupPromise = undefined
      state.teardownPromise = undefined
      state.originalDatabaseUrl = undefined
      state.provisioningDbUrl = undefined
      state.testDbUrl = undefined
    }
  })()

  await state.teardownPromise
}

export const cleanDatabase = async () => {
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
