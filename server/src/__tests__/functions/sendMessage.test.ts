import { describe, test, expect, beforeEach, beforeAll } from "bun:test"
import { InputPeer, Message, MessageEntity_Type, SendMessageResult } from "@inline-chat/protocol/core"
import { setupTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { dialogs, users } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"

// Test state
let currentUser: DbUser
let privateChat: DbChat
let privateChatPeerId: InputPeer
let context: FunctionContext
let userIndex = 0

const runId = Date.now()
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

// Helpers
function extractMessage(result: SendMessageResult): Message | null {
  const update = result.updates[1]
  if (update?.update.oneofKind !== "newMessage") {
    return null
  }
  return update.update.newMessage?.message ?? null
}

describe("sendMessage", () => {
  beforeAll(async () => {
    await setupTestDatabase()
    currentUser = (await testUtils.createUser(nextEmail("test-user")))!
    privateChat = (await testUtils.createPrivateChat(currentUser, currentUser))!
    privateChatPeerId = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(privateChat.id) } },
    }
    context = testUtils.functionContext({ userId: currentUser.id, sessionId: 1 })
  })

  test("should create a text message", async () => {
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
      },
      context,
    )

    expect(result.updates).toHaveLength(2)
    expect(result.updates[1]?.update.oneofKind).toBe("newMessage")

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message?.message).toBe("test")
  })

  test("should return one update if message has duplicate random id", async () => {
    let _ = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
        randomId: 1n,
      },
      context,
    )
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
        randomId: 1n,
      },
      context,
    )

    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("updateMessageId")
  })

  test("should create a text message with empty entities", async () => {
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
        entities: { entities: [] },
      },
      context,
    )

    expect(result.updates).toHaveLength(2)
    const message = extractMessage(result)
    expect(message!.message).toBe("test")
  })

  test("should create a text message with entities", async () => {
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "@mo",
        entities: testUtils.mentionEntities(0, 3),
      },
      context,
    )

    expect(result.updates).toHaveLength(2)
    const message = extractMessage(result)
    expect(message!.message).toBe("@mo")
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.type).toBe(MessageEntity_Type.MENTION)
    expect(message!.entities!.entities[0]!.offset).toBe(0n)
    expect(message!.entities!.entities[0]!.length).toBe(3n)
  })

  test("parses @username mention from text when client does not provide mention entity", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("mentioned-user"))
    await db.update(users).set({ username: "mentioneduser" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @mentioneduser",
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)

    const mentionEntity = message!.entities!.entities[0]!
    expect(mentionEntity.type).toBe(MessageEntity_Type.MENTION)
    expect(mentionEntity.offset).toBe(6n)
    expect(mentionEntity.length).toBe(14n)
    expect(mentionEntity.entity.oneofKind).toBe("mention")
    if (mentionEntity.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(mentionEntity.entity.mention.userId).toBe(BigInt(mentionedUser.id))
  })

  test("does not duplicate mention node when client already provides mention entity", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("provided-mentioned-user"))
    await db.update(users).set({ username: "providedmention" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @providedmention",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.MENTION,
              offset: 6n,
              length: 16n,
              entity: {
                oneofKind: "mention",
                mention: {
                  userId: BigInt(mentionedUser.id),
                },
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.offset).toBe(6n)
    expect(message!.entities!.entities[0]!.length).toBe(16n)
    expect(message!.entities!.entities[0]!.entity.oneofKind).toBe("mention")
    if (message!.entities!.entities[0]!.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(message!.entities!.entities[0]!.entity.mention.userId).toBe(BigInt(mentionedUser.id))
  })

  test("parses only missing @username mentions and keeps provided mention entities", async () => {
    const providedUser = await testUtils.createUser(nextEmail("provided-user"))
    const missingUser = await testUtils.createUser(nextEmail("missing-user"))
    await db.update(users).set({ username: "providednode" }).where(eq(users.id, providedUser.id)).execute()
    await db.update(users).set({ username: "missingnode" }).where(eq(users.id, missingUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "@providednode and @missingnode",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.MENTION,
              offset: 0n,
              length: 13n,
              entity: {
                oneofKind: "mention",
                mention: {
                  userId: BigInt(providedUser.id),
                },
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(2)

    const [providedMention, missingMention] = message!.entities!.entities
    expect(providedMention!.entity.oneofKind).toBe("mention")
    if (providedMention!.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(providedMention!.entity.mention.userId).toBe(BigInt(providedUser.id))
    expect(providedMention!.offset).toBe(0n)
    expect(providedMention!.length).toBe(13n)

    expect(missingMention!.entity.oneofKind).toBe("mention")
    if (missingMention!.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(missingMention!.entity.mention.userId).toBe(BigInt(missingUser.id))
    expect(missingMention!.offset).toBe(18n)
    expect(missingMention!.length).toBe(12n)
  })

  test("does not parse @username when mention range is partly covered by a client entity", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("partial-overlap-user"))
    await db.update(users).set({ username: "partialoverlap" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @partialoverlap world",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.BOLD,
              offset: 9n,
              length: 4n,
              entity: {
                oneofKind: undefined,
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.type).toBe(MessageEntity_Type.BOLD)
    expect(message!.entities!.entities.some((entity) => entity!.type === MessageEntity_Type.MENTION)).toBe(false)
  })

  test("does not parse @username when overlap with client entity is a single character", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("single-char-overlap-user"))
    await db.update(users).set({ username: "singlecharoverlap" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @singlecharoverlap",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.ITALIC,
              offset: 6n,
              length: 1n,
              entity: {
                oneofKind: undefined,
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.type).toBe(MessageEntity_Type.ITALIC)
    expect(message!.entities!.entities.some((entity) => entity!.type === MessageEntity_Type.MENTION)).toBe(false)
  })

  test("unarchives recipient dialog and enqueues a user update", async () => {
    const sender = (await testUtils.createUser(nextEmail("sender")))!
    const recipient = (await testUtils.createUser(nextEmail("recipient")))!
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: sender,
      userB: recipient,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    await db
      .update(dialogs)
      .set({ archived: true })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, recipient.id)))
      .execute()

    const peerId: InputPeer = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } },
    }
    const senderContext = testUtils.functionContext({ userId: sender.id, sessionId: 1 })

    await sendMessage({ peerId, message: "hello" }, senderContext)

    const [updatedDialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, recipient.id)))
      .limit(1)

    expect(updatedDialog?.archived).toBe(false)

    const userUpdates = await db.query.updates.findMany({
      where: {
        bucket: UpdateBucket.User,
        entityId: recipient.id,
      },
    })

    const hasDialogArchivedUpdate = userUpdates
      .map((update) => UpdatesModel.decrypt(update))
      .some(
        (update) =>
          update.payload.update.oneofKind === "userDialogArchived" &&
          update.payload.update.userDialogArchived.archived === false,
      )

    expect(hasDialogArchivedUpdate).toBe(true)
  })
})
