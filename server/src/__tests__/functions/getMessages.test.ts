import { describe, expect, test } from "bun:test"
import { Message, MessageEntity_Type, type InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { messages, users } from "@in/server/db/schema"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { messageSourceSnapshot } from "@in/server/modules/message/sourceSnapshot"
import { encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"
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

  for (const isSticker of [false, true]) {
    test(`stored bot mention has one live/read snapshot with isSticker=${isSticker}`, async () => {
      const author = await testUtils.createUser("snapshot-author@example.test")
      const reader = await testUtils.createUser("snapshot-bot@example.test")
      await db.update(users).set({ bot: true, botCreatorId: author.id }).where(eq(users.id, reader.id))
      const chat = await testUtils.createChat(null, "Snapshot task", "thread", false, author.id)
      if (!chat) throw new Error("Expected independent private task chat")
      await testUtils.addParticipant(chat.id, author.id)
      await testUtils.addParticipant(chat.id, reader.id)
      const row = await testUtils.createTestMessage({
        messageId: 1, chatId: chat.id, fromId: author.id, text: "@QA Chief answer this mention",
        entities: { entities: [{ type: MessageEntity_Type.MENTION, offset: 0n, length: 9n,
          entity: { oneofKind: "mention", mention: { userId: BigInt(reader.id) } },
        }] },
      })
      const [stored] = await db.update(messages).set({ isSticker }).where(and(
        eq(messages.chatId, row.chatId), eq(messages.messageId, row.messageId),
      )).returning()
      if (!stored) throw new Error("Expected persisted encrypted mention")
      const peerId = makeChatPeer(chat.id)
      const live = encodeMessage({ message: stored, encodingForUserId: reader.id, encodingForPeer: { inputPeer: peerId } })
      const result = await getMessages({ peerId, messageIds: [1n] }, testUtils.functionContext({ userId: reader.id }))
      const read = result.messages[0]
      if (!read) throw new Error("Expected authorized bot to read its mention")
      const liveToken = live.sourceSnapshot
      if (!liveToken || !read.sourceSnapshot) throw new Error("Expected both encoders to issue public snapshot tokens")
      expect(live.mentioned).toBe(true)
      expect(read.mentioned).toBe(true)
      expect(live.isSticker).toBe(isSticker ? true : undefined)
      expect(read.isSticker).toBe(isSticker)
      expect(read.sourceSnapshot).toBe(liveToken)
      for (const variant of [live, read, Message.fromBinary(Message.toBinary(live)),
        Message.fromBinary(Message.toBinary(read)), Message.fromJson(Message.toJson(live)), Message.fromJson(Message.toJson(read))]) {
        expect(messageSourceSnapshot(variant)).toBe(liveToken)
      }
      expect(messageSourceSnapshot(Message.create({ ...read, isSticker: !isSticker }))).not.toBe(liveToken)
    })
  }

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
