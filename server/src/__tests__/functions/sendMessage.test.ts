import { describe, test, expect, beforeEach, beforeAll } from "bun:test"
import { InputPeer, Message, MessageEntity_Type, SendMessageResult } from "@inline-chat/protocol/core"
import { setupTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
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
