import { db } from "../db"
import { migrateDb } from "../../scripts/helpers/migrate-db"
import postgres from "postgres"
import { beforeEach, afterEach, beforeAll, afterAll } from "bun:test"
import * as schema from "../db/schema"
import { sql, eq } from "drizzle-orm"

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
  async createChat(
    spaceId: number,
    title: string = "Test Chat",
    type: "private" | "thread" = "thread",
    publicThread: boolean = true,
  ) {
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type,
        title,
        spaceId,
        publicThread,
      })
      .returning()
    return chat
  },
  async createPrivateChat(userA: schema.DbUser, userB: schema.DbUser) {
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "private",
        minUserId: Math.min(userA.id, userB.id),
        maxUserId: Math.max(userA.id, userB.id),
      })
      .returning()
    return chat
  },

  // Add participant to chat
  async addParticipant(chatId: number, userId: number) {
    await db.insert(schema.chatParticipants).values({ chatId, userId }).execute()
  },

  // Create a space and add members
  async createSpaceWithMembers(spaceName: string, userEmails: string[]): Promise<{ space: any; users: any[] }> {
    const space = await testUtils.createSpace(spaceName)
    if (!space) throw new Error("Failed to create space")
    const users = await Promise.all(userEmails.map((email) => testUtils.createUser(email)))
    const validUsers = users.filter((u) => u)
    if (validUsers.length !== users.length) throw new Error("Failed to create one or more users")
    await db
      .insert(schema.members)
      .values(validUsers.map((u) => ({ userId: u!.id, spaceId: space.id, role: "member" as const })))
      .execute()
    return { space, users: validUsers }
  },

  // Create a thread chat (public or private) with dialog and message for a user
  async createThreadWithDialogAndMessage({
    spaceId,
    user,
    otherUsers = [],
    title = "Thread Chat",
    isPublic = true,
    messageText = "Hello thread",
    messageFromUser = null,
  }: {
    spaceId: number
    user: any
    otherUsers?: any[]
    title?: string
    isPublic?: boolean
    messageText?: string
    messageFromUser?: any | null
  }): Promise<{ chat: any; msg: any }> {
    const chat = await testUtils.createChat(spaceId, title, "thread", isPublic)
    if (!chat) throw new Error("Failed to create chat")

    // Add participants for private threads
    if (!isPublic) {
      await db
        .insert(schema.chatParticipants)
        .values([user, ...otherUsers].map((u) => ({ chatId: chat.id, userId: u.id })))
        .execute()
    }
    // Create dialog for user
    await db.insert(schema.dialogs).values({ userId: user.id, chatId: chat.id, spaceId }).execute()
    // Create message
    const fromUser = messageFromUser || user
    const msg = await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: fromUser.id,
        text: messageText,
      })
      .returning()
      .then((rows) => rows[0])
    if (!msg) throw new Error("Failed to create message")
    // Set lastMsgId on chat
    await db.update(schema.chats).set({ lastMsgId: msg.messageId }).where(eq(schema.chats.id, chat.id)).execute()
    return { chat, msg }
  },

  // Create a DM chat with dialog and message for two users in a space
  async createDMWithDialogAndMessage({
    spaceId,
    userA,
    userB,
    messageText = "Hey DM!",
    messageFromUser = null,
  }: {
    spaceId: number
    userA: any
    userB: any
    messageText?: string
    messageFromUser?: any | null
  }): Promise<{ chat: any; msg: any }> {
    const chat = await db
      .insert(schema.chats)
      .values({
        type: "private",
        minUserId: Math.min(userA.id, userB.id),
        maxUserId: Math.max(userA.id, userB.id),
        title: "DM Chat",
      })
      .returning()
      .then((rows) => rows[0])
    if (!chat) throw new Error("Failed to create DM chat")
    await db
      .insert(schema.dialogs)
      .values([
        { userId: userA.id, chatId: chat.id, peerUserId: userB.id, spaceId },
        { userId: userB.id, chatId: chat.id, peerUserId: userA.id, spaceId },
      ])
      .execute()
    const fromUser = messageFromUser || userB
    const msg = await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: fromUser.id,
        text: messageText,
      })
      .returning()
      .then((rows) => rows[0])
    if (!msg) throw new Error("Failed to create message")
    await db.update(schema.chats).set({ lastMsgId: msg.messageId }).where(eq(schema.chats.id, chat.id)).execute()
    return { chat, msg }
  },

  // Create a private chat with optional dialog for specific users
  async createPrivateChatWithOptionalDialog({
    userA,
    userB,
    createDialogForUserA = true,
    createDialogForUserB = false,
  }: {
    userA: any
    userB: any
    createDialogForUserA?: boolean
    createDialogForUserB?: boolean
  }): Promise<{ chat: any; dialogA?: any; dialogB?: any }> {
    const chat = await db
      .insert(schema.chats)
      .values({
        type: "private",
        minUserId: Math.min(userA.id, userB.id),
        maxUserId: Math.max(userA.id, userB.id),
        date: new Date(),
      })
      .returning()
      .then((rows) => rows[0])
    if (!chat) throw new Error("Failed to create private chat")

    const dialogs = []
    if (createDialogForUserA) {
      const [dialogA] = await db
        .insert(schema.dialogs)
        .values({
          chatId: chat.id,
          userId: userA.id,
          peerUserId: userB.id,
          date: new Date(),
        })
        .returning()
      if (dialogA) dialogs.push(dialogA)
    }

    if (createDialogForUserB) {
      const [dialogB] = await db
        .insert(schema.dialogs)
        .values({
          chatId: chat.id,
          userId: userB.id,
          peerUserId: userA.id,
          date: new Date(),
        })
        .returning()
      if (dialogB) dialogs.push(dialogB)
    }

    return {
      chat,
      dialogA: dialogs.find((d) => d.userId === userA.id),
      dialogB: dialogs.find((d) => d.userId === userB.id),
    }
  },
}

// Export lifecycle hooks
export const setupTestLifecycle = () => {
  beforeAll(setupTestDatabase)
  afterAll(teardownTestDatabase)
  beforeEach(cleanDatabase)
}
