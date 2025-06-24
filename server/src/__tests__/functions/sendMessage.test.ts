import { describe, test, expect, beforeEach, beforeAll } from "bun:test"
import { InputPeer, Message, MessageEntity_Type, SendMessageResult } from "@in/protocol/core"
import { setupTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"

// Test state
let currentUser: DbUser
let privateChat: DbChat
let privateChatPeerId: InputPeer
let context: FunctionContext

// Helpers
function extractMessage(result: SendMessageResult): Message | null {
  return result.updates[1]?.update.oneofKind === "newMessage" ? result.updates[1]?.update.newMessage?.message! : null
}

describe("sendMessage", () => {
  beforeAll(async () => {
    await setupTestDatabase()
    currentUser = (await testUtils.createUser("test@example.com"))!
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
})
