import { describe, expect, test } from "bun:test"
import type { InputPeer } from "@inline-chat/protocol/core"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { testUtils, setupTestLifecycle } from "../setup"

const makeFunctionContext = (userId: number): any => ({
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

  test("throws MESSAGE_ID_INVALID for non-positive IDs", async () => {
    const userA = (await testUtils.createUser("get-messages-invalid-a@example.com"))!
    const userB = (await testUtils.createUser("get-messages-invalid-b@example.com"))!
    await testUtils.createPrivateChat(userA, userB)

    await expect(
      getMessages(
        {
          peerId: makeUserPeer(userB.id),
          messageIds: [0n],
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
