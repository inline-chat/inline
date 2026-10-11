import { describe, expect, test } from "bun:test"
import { Method, type InputPeer } from "@inline-chat/protocol/core"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"
import { chats, messages } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { botOperationHandlers } from "@in/server/controllers/bot/operations"
import { testUtils, setupTestLifecycle } from "../setup"

const makeFunctionContext = (userId: number): FunctionContext => ({
  currentUserId: userId,
  currentSessionId: 1,
})

const makeUserPeer = (userId: number): InputPeer => ({
  type: {
    oneofKind: "user",
    user: { userId: BigInt(userId) },
  },
})

const makeChatPeer = (chatId: number): InputPeer => ({
  type: {
    oneofKind: "chat",
    chat: { chatId: BigInt(chatId) },
  },
})

describe("getMessages", () => {
  setupTestLifecycle()

  test.each([
    { kind: "unique", messageIds: Array.from({ length: 1_001 }, (_, index) => BigInt(index + 1)) },
    { kind: "duplicate", messageIds: Array<bigint>(1_001).fill(1n) },
  ])("rejects more than 1,000 $kind input IDs before creating a missing DM", async ({ messageIds }) => {
    const userA = await testUtils.createUser("get-messages-cap-a@example.com")
    const userB = await testUtils.createUser("get-messages-cap-b@example.com")
    const before = await db.select({ id: chats.id }).from(chats)

    await expect(getMessages({
      peerId: makeUserPeer(userB.id),
      messageIds,
    }, makeFunctionContext(userA.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })

    expect(await db.select({ id: chats.id }).from(chats)).toEqual(before)
  })

  test.each([
    { kind: "unique", messageIds: Array.from({ length: 1_001 }, (_, index) => index + 1) },
    { kind: "duplicate", messageIds: Array<number>(1_001).fill(1) },
  ])("the legacy Bot adapter rejects more than 1,000 $kind raw IDs before DM creation or hydration", async ({ messageIds }) => {
    const userA = await testUtils.createUser("get-messages-bot-cap-a@example.com")
    const userB = await testUtils.createUser("get-messages-bot-cap-b@example.com")
    const before = await db.select({ id: chats.id }).from(chats)

    await expect(botOperationHandlers.getMessages({
      user_id: userB.id, message_ids: messageIds,
    }, { ...makeFunctionContext(userA.id), ip: undefined })).rejects.toMatchObject({
      code: 400, type: "BAD_REQUEST",
    })

    expect(await db.select({ id: chats.id }).from(chats)).toEqual(before)
  })

  test("the legacy Bot adapter retains within-limit invalid-ID errors", async () => {
    const user = await testUtils.createUser("get-messages-bot-invalid@example.com")
    await expect(botOperationHandlers.getMessages({
      user_id: user.id, message_ids: ["not-an-id"],
    }, { ...makeFunctionContext(user.id), ip: undefined })).rejects.toMatchObject({
      code: 400, type: "BAD_REQUEST",
    })
  })

  test("returns all 1,000 requested unique messages at the input boundary", async () => {
    const userA = await testUtils.createUser("get-messages-boundary-a@example.com")
    const userB = await testUtils.createUser("get-messages-boundary-b@example.com")
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Expected a private chat fixture")
    const ids = Array.from({ length: 1_000 }, (_, index) => index + 1)
    await db.insert(messages).values(ids.map((messageId) => ({
      messageId, chatId: chat.id, fromId: userA.id, text: `message ${messageId}`,
    })))

    const requested = ids.toReversed().map(BigInt)
    const result = await getMessages({
      peerId: makeChatPeer(chat.id), messageIds: requested,
    }, makeFunctionContext(userA.id))

    expect(result.messages.map((message) => message.id)).toEqual(requested)
    expect(result.messages.map((message) => message.message)).toEqual(ids.toReversed().map((id) => `message ${id}`))
  })

  test("accepts 1,000 raw IDs while preserving duplicate removal, order, and missing-ID behavior", async () => {
    const userA = await testUtils.createUser("get-messages-duplicate-a@example.com")
    const userB = await testUtils.createUser("get-messages-duplicate-b@example.com")
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Expected a private chat fixture")
    await testUtils.createTestMessage({ messageId: 1, chatId: chat.id, fromId: userA.id, text: "first" })
    await testUtils.createTestMessage({ messageId: 2, chatId: chat.id, fromId: userA.id, text: "second" })

    const requested = [2n, 999n, ...Array<bigint>(997).fill(2n), 1n]
    const result = await getMessages({
      peerId: makeChatPeer(chat.id), messageIds: requested,
    }, makeFunctionContext(userA.id))

    expect(result.messages.map((message) => message.id)).toEqual([2n, 1n])
    expect(result.messages.map((message) => message.message)).toEqual(["second", "first"])
  })

  test("the shared V2/V3 RPC dispatcher rejects oversized exact-message requests before peer lookup", async () => {
    const userA = await testUtils.createUser("get-messages-rpc-a@example.com")
    const userB = await testUtils.createUser("get-messages-rpc-b@example.com")
    const before = await db.select({ id: chats.id }).from(chats)
    await expect(handleRpcCall({
      method: Method.GET_MESSAGES,
      input: {
        oneofKind: "getMessages",
        getMessages: { peerId: makeUserPeer(userB.id), messageIds: Array<bigint>(1_001).fill(1n) },
      },
    }, {
      userId: userA.id, sessionId: 1, connectionId: "get-messages-cap",
      sendRaw: () => { throw new Error("Oversized request must not emit updates") },
      sendRpcReply: () => { throw new Error("Oversized request must not emit replies") },
    })).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(await db.select({ id: chats.id }).from(chats)).toEqual(before)
  })

  test("still returns an empty exact-message snapshot for an empty ID list", async () => {
    const userA = await testUtils.createUser("get-messages-empty-a@example.com")
    const userB = await testUtils.createUser("get-messages-empty-b@example.com")
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Expected a private chat fixture")
    const result = await getMessages({
      peerId: makeChatPeer(chat.id), messageIds: [],
    }, makeFunctionContext(userA.id))
    expect(result).toEqual({ messages: [], seq: BigInt(chat.updateSeq ?? 0) })
  })

  test("returns full messages in requested order and skips missing IDs", async () => {
    const userA = (await testUtils.createUser("get-messages-a@example.com"))!
    const userB = (await testUtils.createUser("get-messages-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userA.id,
      text: "first",
    })
    await testUtils.createTestMessage({
      messageId: 2,
      chatId: chat.id,
      fromId: userB.id,
      text: "second",
    })
    await testUtils.createTestMessage({
      messageId: 3,
      chatId: chat.id,
      fromId: userA.id,
      text: "third",
    })

    const result = await getMessages(
      {
        peerId: makeUserPeer(userB.id),
        messageIds: [3n, 999n, 1n],
      },
      makeFunctionContext(userA.id),
    )

    expect(result.messages.map((message) => Number(message.id))).toEqual([3, 1])
    expect(result.messages.map((message) => message.message)).toEqual(["third", "first"])
  })

  test.each([0n, -1n, 2_147_483_648n])("throws MESSAGE_ID_INVALID for an out-of-range ID %s within the input cap", async (invalidId) => {
    const userA = (await testUtils.createUser("get-messages-invalid-a@example.com"))!
    const userB = (await testUtils.createUser("get-messages-invalid-b@example.com"))!
    await testUtils.createPrivateChat(userA, userB)

    await expect(
      getMessages(
        {
          peerId: makeUserPeer(userB.id),
          messageIds: [invalidId],
        },
        makeFunctionContext(userA.id),
      ),
    ).rejects.toMatchObject({
      code: RealtimeRpcError.Code.MESSAGE_ID_INVALID,
    })
  })

  test("rejects access to thread messages for non-participants", async () => {
    const owner = (await testUtils.createUser("get-messages-thread-owner@example.com"))!
    const participant = (await testUtils.createUser("get-messages-thread-participant@example.com"))!
    const outsider = (await testUtils.createUser("get-messages-thread-outsider@example.com"))!

    const chat = (await testUtils.createChat(null, "Home Thread", "thread", false, owner.id))!
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, participant.id)

    await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: owner.id,
      text: "only participants can read this",
    })

    await expect(
      getMessages(
        {
          peerId: makeChatPeer(chat.id),
          messageIds: [1n],
        },
        makeFunctionContext(outsider.id),
      ),
    ).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })
  })
})
