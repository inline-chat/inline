import { mock } from "bun:test"
import { db } from "../db"
import { migrateDb } from "../../scripts/helpers/migrate-db"
import postgres from "postgres"
import { beforeEach, afterEach, beforeAll, afterAll } from "bun:test"
import * as schema from "../db/schema"
import { sql } from "drizzle-orm"

// Set test environment
process.env.NODE_ENV = "test"
process.env.RESEND_API_KEY = process.env.RESEND_API_KEY || "test-key"
process.env["ENCRYPTION_KEY"] =
  process.env["ENCRYPTION_KEY"] || "1234567890123456789012345678901212345678901234567890123456789012"
process.env.AMAZON_ACCESS_KEY = process.env.AMAZON_ACCESS_KEY || "test-key"
process.env.AMAZON_SECRET_ACCESS_KEY = process.env.AMAZON_SECRET_ACCESS_KEY || "test-secret"

// Test database configuration
const TEST_DB_NAME = "test_db"
let originalDbUrl: string
let testDbUrl: string
let adminDb: postgres.Sql

// Test context type
export interface TestContext {
  userId: number
  sessionId: number
  connectionId: string
}

// Default test context
export const defaultTestContext: TestContext = {
  userId: 123,
  sessionId: 456,
  connectionId: "connection-123",
}

// Database setup and teardown functions
export const setupTestDatabase = async () => {
  try {
    // Store original database URL
    originalDbUrl = process.env.DATABASE_URL!

    // Create test database URL
    const parts = originalDbUrl.split("/")
    const databaseWithoutDb = parts.slice(0, -1).join("/")
    testDbUrl = `${databaseWithoutDb}/${TEST_DB_NAME}`

    // Create admin connection to create/drop the test database
    adminDb = postgres(databaseWithoutDb, {
      max: 1,
      database: "postgres",
      idle_timeout: 10,
    })

    // Check if database exists before trying to drop it
    const dbExists = await adminDb`
      SELECT 1 FROM pg_database WHERE datname = ${TEST_DB_NAME}
    `

    if (dbExists.length > 0) {
      // Disconnect all connections to the test database
      await adminDb.unsafe(`
        SELECT pg_terminate_backend(pg_stat_activity.pid)
        FROM pg_stat_activity
        WHERE pg_stat_activity.datname = '${TEST_DB_NAME}'
        AND pid <> pg_backend_pid()
      `)

      // Drop existing test database
      await adminDb.unsafe(`DROP DATABASE IF EXISTS ${TEST_DB_NAME} WITH (FORCE)`)
    }

    // Create fresh test database
    await adminDb.unsafe(`CREATE DATABASE ${TEST_DB_NAME}`)

    // Close admin connection
    await adminDb.end()

    // Set test database URL for the test run
    process.env.DATABASE_URL = testDbUrl

    // Run migrations on the new database
    await migrateDb()
  } catch (error) {
    console.error("Test database setup failed:", error)
    throw error
  }
}

export const teardownTestDatabase = async () => {
  try {
    // Create admin connection again for cleanup
    const parts = originalDbUrl.split("/")
    const databaseWithoutDb = parts.slice(0, -1).join("/")
    adminDb = postgres(databaseWithoutDb, {
      max: 1,
      database: "postgres",
      idle_timeout: 10,
    })

    // Check if database exists before trying to drop it
    const dbExists = await adminDb`
      SELECT 1 FROM pg_database WHERE datname = ${TEST_DB_NAME}
    `

    if (dbExists.length > 0) {
      // Disconnect all connections to the test database
      await adminDb.unsafe(`
        SELECT pg_terminate_backend(pg_stat_activity.pid)
        FROM pg_stat_activity
        WHERE pg_stat_activity.datname = '${TEST_DB_NAME}'
        AND pid <> pg_backend_pid()
      `)

      // Drop test database
      await adminDb.unsafe(`DROP DATABASE IF EXISTS ${TEST_DB_NAME} WITH (FORCE)`)
    }

    await adminDb.end()

    // Restore original database URL
    process.env.DATABASE_URL = originalDbUrl
  } catch (error) {
    console.error("Test cleanup failed:", error)
  }
}

export const cleanDatabase = async () => {
  try {
    // Get all tables from the schema
    const tables = Object.values(schema).filter((table) => typeof table === "object" && "name" in table) as any[]

    // Use raw SQL to truncate all tables in the correct order
    // This ensures foreign key constraints are respected
    await db.execute(sql`
      SET client_min_messages TO WARNING;
      DO $$ DECLARE
        r RECORD;
      BEGIN
        -- Disable all triggers temporarily
        FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
          EXECUTE 'ALTER TABLE ' || quote_ident(r.tablename) || ' DISABLE TRIGGER ALL';
        END LOOP;

        -- Truncate all tables
        FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
          EXECUTE 'TRUNCATE TABLE ' || quote_ident(r.tablename) || ' CASCADE';
        END LOOP;

        -- Re-enable all triggers
        FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
          EXECUTE 'ALTER TABLE ' || quote_ident(r.tablename) || ' ENABLE TRIGGER ALL';
        END LOOP;
      END $$;
      SET client_min_messages TO NOTICE;
    `)
  } catch (error) {
    console.error("Failed to clean database before test:", error)
    throw error
  }
}

// Utility functions for tests
export const testUtils = {
  // Create a test user
  async createUser(email: string = "test@example.com") {
    const [user] = await db.insert(schema.users).values({ email }).returning()
    return user
  },

  // Create a test space
  async createSpace(name: string = "Test Space") {
    const [space] = await db.insert(schema.spaces).values({ name }).returning()
    return space
  },

  // Create a test chat
  async createChat(spaceId: number, title: string = "Test Chat", type: "private" | "thread" = "thread") {
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type,
        title,
        spaceId,
        publicThread: type === "thread",
      })
      .returning()
    return chat
  },

  // Add participant to chat
  async addParticipant(chatId: number, userId: number) {
    await db.insert(schema.chatParticipants).values({ chatId, userId }).execute()
  },
}

// Export lifecycle hooks
export const setupTestLifecycle = () => {
  // Mock external services
  mock.module("../libs/resend", () => ({
    sendEmail: mock().mockResolvedValue(true),
  }))

  beforeAll(setupTestDatabase)
  afterAll(teardownTestDatabase)
  beforeEach(cleanDatabase)
}
