import { describe, expect, test } from "bun:test"
import { Method } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { pinMessage } from "@in/server/functions/messages.pinMessage"
import { unpinAllMessages } from "@in/server/functions/messages.unpinAllMessages"
import { inlineProtocolRpcExecutionLane } from "@in/server/modules/inlineProtocol/application"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { and, eq, isNotNull } from "drizzle-orm"

setupTestLifecycle()

const setupChat = async (label: string) => {
  const owner = await testUtils.createUser(`unpin-all-owner-${label}@example.com`)
  const member = await testUtils.createUser(`unpin-all-member-${label}@example.com`)
  const chat = await testUtils.createChat(null, "Unpin All Thread", "thread", false, owner.id)
  if (!chat) {
    throw new Error("Failed to create unpin all test chat")
  }
  await testUtils.addParticipant(chat.id, owner.id)
  await testUtils.addParticipant(chat.id, member.id)

  const peer = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
  return { owner, member, chat, peer }
}

const send = async (peer: Parameters<typeof sendMessage>[0]["peerId"], userId: number, text: string) => {
  const sent = await sendMessage({ peerId: peer, message: text }, testUtils.functionContext({ userId, sessionId: 1 }))
  const update = sent.updates[0]?.update
  if (update?.oneofKind !== "updateMessageId") {
    throw new Error("Expected a message id update")
  }
  return update.updateMessageId.messageId
}

const chatSeq = async (chatId: number) => {
  const [row] = await db.select({ updateSeq: schema.chats.updateSeq }).from(schema.chats).where(eq(schema.chats.id, chatId))
  return row?.updateSeq ?? null
}

const pinnedIds = async (chatId: number) =>
  (
    await db
      .select({ messageId: schema.messages.messageId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, chatId), isNotNull(schema.messages.pinnedAt)))
  ).map((row) => row.messageId)

describe("messages.unpinAllMessages", () => {
  test("unpins every message with a single empty pin list update", async () => {
    const { owner, member, chat, peer } = await setupChat("all")
    const ids = [await send(peer, owner.id, "one"), await send(peer, owner.id, "two"), await send(peer, member.id, "three")]
    for (const messageId of ids) {
      await pinMessage({ peer, messageId, unpin: false }, testUtils.functionContext({ userId: owner.id, sessionId: 1 }))
    }
    expect(await pinnedIds(chat.id)).toHaveLength(3)
    const seqBefore = await chatSeq(chat.id)

    // Any participant can unpin, as with single pins.
    const result = await unpinAllMessages({ peer }, testUtils.functionContext({ userId: member.id, sessionId: 2 }))

    expect(await pinnedIds(chat.id)).toEqual([])
    expect(await chatSeq(chat.id)).toBe((seqBefore ?? 0) + 1)
    expect(result.updates).toHaveLength(1)
    const update = result.updates[0]!
    expect(update.update.oneofKind).toBe("pinnedMessages")
    if (update.update.oneofKind === "pinnedMessages") {
      expect(update.update.pinnedMessages.messageIds).toEqual([])
    }
    expect(update.seq).toBe((seqBefore ?? 0) + 1)
  })

  test("does nothing when the chat has no pins", async () => {
    const { owner, chat, peer } = await setupChat("none")
    await send(peer, owner.id, "unpinned")
    const seqBefore = await chatSeq(chat.id)

    const result = await unpinAllMessages({ peer }, testUtils.functionContext({ userId: owner.id, sessionId: 1 }))

    expect(result.updates).toEqual([])
    expect(await chatSeq(chat.id)).toBe(seqBefore)
  })

  test("rejects users without access to the chat", async () => {
    const { owner, chat, peer } = await setupChat("access")
    const messageId = await send(peer, owner.id, "keep me pinned")
    await pinMessage({ peer, messageId, unpin: false }, testUtils.functionContext({ userId: owner.id, sessionId: 1 }))
    const outsider = await testUtils.createUser("unpin-all-outsider@example.com")

    await expect(
      unpinAllMessages({ peer }, testUtils.functionContext({ userId: outsider.id, sessionId: 3 })),
    ).rejects.toThrow()
    expect(await pinnedIds(chat.id)).toEqual([Number(messageId)])
  })

  test("runs in the chat's peer lane like other pin changes", () => {
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: 42n } } }
    const lane = inlineProtocolRpcExecutionLane({
      method: Method.UNPIN_ALL_MESSAGES,
      input: { oneofKind: "unpinAllMessages", unpinAllMessages: { peerId } },
    })

    expect(lane).toBe("chat:42")
  })
})
