import { db, schema } from "../db"
import { eq } from "drizzle-orm"
import { chats, messages, type DbChat, type DbMessage } from "@in/server/db/schema"
import { encrypt, encryptBinary } from "@in/server/modules/encryption/encryption"
import { MessageEntities, MessageEntity_Type } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { generateToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"

export {
  cleanDatabase,
  setupTestDatabase,
  setupTestLifecycle,
  teardownTestDatabase,
} from "./database"

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

// Utility functions for tests
export const testUtils = {
  // Create a test user
  async createUser(email: string = "test@example.com"): Promise<schema.DbUser> {
    const [user] = await db.insert(schema.users).values({ email }).returning()
    if (!user) {
      throw new Error("Failed to create test user")
    }
    return user
  },

  // Create a valid auth session and return the raw token for API/realtime tests.
  async createSessionForUser(
    userId: number,
    options?: {
      clientType?: "ios" | "macos" | "web" | "api" | "android" | "cli"
      deviceId?: string
      deviceName?: string
      osVersion?: string
      clientVersion?: string
    },
  ): Promise<{ token: string; tokenHash: string; session: Awaited<ReturnType<typeof SessionsModel.create>> }> {
    const { token, tokenHash } = await generateToken(userId)
    const session = await SessionsModel.create({
      userId,
      tokenHash,
      personalData: {
        deviceName: options?.deviceName,
      },
      clientType: options?.clientType ?? "web",
      deviceId: options?.deviceId,
      osVersion: options?.osVersion,
      clientVersion: options?.clientVersion,
    })

    return { token, tokenHash, session }
  },

  // Create a test space
  async createSpace(name: string = "Test Space") {
    const [space] = await db.insert(schema.spaces).values({ name }).returning()
    return space
  },

  // Create a test chat
  async createChat(
    spaceId: number | null,
    title: string = "Test Chat",
    type: "private" | "thread" = "thread",
    publicThread: boolean = true,
    createdBy?: number,
  ) {
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type,
        title,
        spaceId,
        publicThread,
        createdBy: createdBy ?? null,
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
        { userId: userA.id, chatId: chat.id, peerUserId: userB.id, spaceId, ...dialogOpenDefaultsForChat(chat) },
        { userId: userB.id, chatId: chat.id, peerUserId: userA.id, spaceId, ...dialogOpenDefaultsForChat(chat) },
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
          ...dialogOpenDefaultsForChat(chat),
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
          ...dialogOpenDefaultsForChat(chat),
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

  async createTestChat(): Promise<DbChat> {
    let result = await db
      .insert(chats)
      .values({
        type: "private",
      })
      .returning()

    return result[0]!
  },

  async createTestMessage({
    messageId,
    chatId,
    fromId,
    text,
    entities,
  }: {
    messageId: number
    chatId: number
    fromId: number
    text: string
    entities?: MessageEntities
  }): Promise<DbMessage> {
    let encrypted = encrypt(text)
    let encryptedEntities = entities ? encryptBinary(MessageEntities.toBinary(entities)) : undefined
    let result = await db
      .insert(messages)
      .values({
        fromId,
        messageId,
        chatId,
        textEncrypted: encrypted.encrypted,
        textIv: encrypted.iv,
        textTag: encrypted.authTag,
        entitiesEncrypted: encryptedEntities?.encrypted,
        entitiesIv: encryptedEntities?.iv,
        entitiesTag: encryptedEntities?.authTag,
      })
      .returning()

    return result[0]!
  },

  mentionEntities(offset: number, length: number): MessageEntities {
    return {
      entities: [
        {
          type: MessageEntity_Type.MENTION,
          offset: BigInt(offset),
          length: BigInt(length),
          entity: {
            oneofKind: "mention",
            mention: {
              userId: 2n,
            },
          },
        },
      ],
    }
  },

  functionContext: ({ sessionId, userId }: { sessionId?: number; userId?: number }): FunctionContext => {
    return {
      currentSessionId: sessionId ?? defaultTestContext.sessionId,
      currentUserId: userId ?? defaultTestContext.userId,
    }
  },
}
