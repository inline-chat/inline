import { describe, expect, test } from "bun:test"
import { and, asc, eq, sql } from "drizzle-orm"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chats, dialogs, messages, updates, UpdateBucket } from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { UpdatesModel } from "@in/server/db/models/updates"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { dialogOrderForPlacement } from "@in/server/modules/dialogOpen"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

setupTestLifecycle()

async function scenario() {
  const sender = await testUtils.createUser("sender@example.test")
  const recipient = await testUtils.createUser("recipient@example.test")
  const outsider = await testUtils.createUser("outsider@example.test")
  const chat = await testUtils.createPrivateChat(sender, recipient)
  if (!chat) throw new Error("Expected private chat")
  const peer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
  const context = (userId: number) => testUtils.functionContext({ userId })
  const send = (randomId: bigint, userId = sender.id) => sendMessage({ peerId: peer, message: "Hello from a real writer", randomId }, context(userId))
  const history = (userId = recipient.id) => getChatHistory({ peerId: peer, limit: 100 }, context(userId))
  const snapshot = async () => ({
    chat: await db.select().from(chats).where(eq(chats.id, chat.id)),
    messages: await db.select().from(messages).where(eq(messages.chatId, chat.id)).orderBy(asc(messages.messageId)),
    updates: await db.select().from(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id))).orderBy(asc(updates.seq)),
    dialogs: await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id)).orderBy(asc(dialogs.userId)),
  })
  return { sender, recipient, outsider, chat, peer, context, send, history, snapshot }
}

describe("message integrity across real functions and PostgreSQL", () => {
  test("send, edit, delete and resend agree with history and durable replay", async () => {
    const s = await scenario()
    await s.send(1n)
    expect((await s.history()).messages.map((message) => [message.id, message.message])).toEqual([[1n, "Hello from a real writer"]])
    await editMessage({ peer: s.peer, messageId: 1n, text: "Edited text" }, s.context(s.sender.id))
    expect((await s.history()).messages.map((message) => message.message)).toEqual(["Edited text"])
    await deleteMessage({ peer: s.peer, messageIds: [1n] }, s.context(s.sender.id))
    expect((await s.history()).messages).toHaveLength(0)
    await s.send(2n)
    expect((await s.history()).messages.map((message) => message.id)).toEqual([2n])
    const state = await s.snapshot()
    expect(state.chat[0]).toMatchObject({ lastMsgId: 2, messageIdCounter: 2 })
    const events = state.updates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)
    expect(events).toEqual(["newMessage", "editMessage", "deleteMessages", "newMessage"])
    expect(state.updates.map((row) => row.seq)).toEqual([1, 2, 3, 4])
    expect(state.chat[0]?.updateSeq).toBe(4)
  })

  test("simultaneous retries commit one message, one replay event and one sequence", async () => {
    const s = await scenario()
    const attempts = await Promise.allSettled(Array.from({ length: 8 }, () => s.send(41n)))
    expect(attempts.map((attempt) => attempt.status)).toEqual(Array(8).fill("fulfilled"))
    const results = attempts.flatMap((attempt) => attempt.status === "fulfilled" ? [attempt.value] : [])
    const state = await s.snapshot()
    expect(state.messages).toHaveLength(1)
    expect(state.updates).toHaveLength(1)
    expect(state.chat[0]).toMatchObject({ lastMsgId: 1, messageIdCounter: 1, updateSeq: 1 })
    for (const result of results) {
      const mapping = result.updates.find((update) => update.update.oneofKind === "updateMessageId")
      expect(mapping?.update).toMatchObject({ oneofKind: "updateMessageId", updateMessageId: { messageId: 1n, randomId: 41n } })
    }
    expect((await s.history()).messages).toHaveLength(1)
  })

  test("idempotency is per sender while distinct concurrent sends retain every message", async () => {
    const s = await scenario()
    const results = await Promise.allSettled([s.send(91n), s.send(91n, s.recipient.id), s.send(92n), s.send(93n)])
    expect(results.map((result) => result.status)).toEqual(["fulfilled", "fulfilled", "fulfilled", "fulfilled"])
    const state = await s.snapshot()
    expect(state.messages.map((message) => message.messageId)).toEqual([1, 2, 3, 4])
    expect(state.updates.map((update) => update.seq)).toEqual([1, 2, 3, 4])
    expect(state.messages.filter((message) => message.randomId === 91n).map((message) => message.fromId).sort()).toEqual([s.sender.id, s.recipient.id].sort())
    expect(state.chat[0]).toMatchObject({ lastMsgId: 4, messageIdCounter: 4, updateSeq: 4 })
  })

  test.each(["read", "send", "edit", "delete"] as const)("an outsider cannot %s or leave any chat side effects", async (operation) => {
    const s = await scenario()
    await s.send(1n)
    // Warm authorized access first: cached permission must remain actor-scoped.
    await s.history()
    const before = await s.snapshot()
    const attempt = () => {
      switch (operation) {
        case "read": return s.history(s.outsider.id)
        case "send": return s.send(2n, s.outsider.id)
        case "edit": return editMessage({ peer: s.peer, messageId: 1n, text: "Tampered" }, s.context(s.outsider.id))
        case "delete": return deleteMessage({ peer: s.peer, messageIds: [1n] }, s.context(s.outsider.id))
      }
    }
    await expect(attempt()).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    expect(await s.snapshot()).toEqual(before)
    expect((await s.history()).messages[0]?.message).toBe("Hello from a real writer")
  })

  test("dialog ordering does not block a concurrent message foreign-key check", async () => {
    const s = await scenario()
    const acquired = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const owner = db.transaction(async (tx) => {
      await dialogOrderForPlacement(tx, s.sender.id, "bottom")
      acquired.resolve()
      await release.promise
    })
    // Race with the owner so a failed lock acquisition cannot hang the test.
    await Promise.race([acquired.promise, owner])
    try {
      const inserted = await db.transaction(async (tx) => {
        await tx.execute(sql`SET LOCAL lock_timeout = '1s'`)
        return MessageModel.insertMessage({ chatId: s.chat.id, fromId: s.sender.id }, undefined, tx)
      })
      expect(inserted.message.messageId).toBe(1)
    } finally {
      release.resolve()
      await owner
    }
  })

  test("a database failure after message insertion rolls back the message and sequence together", async () => {
    const s = await scenario()
    const before = await s.snapshot()
    // Fail at the actual durable-write boundary. Mocking insertMessage would not
    // establish that the earlier message INSERT shares this transaction.
    await db.execute(sql`CREATE FUNCTION test_reject_update() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test injected replay failure'; END $$;
      CREATE TRIGGER test_reject_update BEFORE INSERT ON updates
      FOR EACH ROW EXECUTE FUNCTION test_reject_update();`)
    try {
      await expect(MessageModel.insertMessage({ chatId: s.chat.id, fromId: s.sender.id, randomId: 7n })).rejects.toThrow("test injected replay failure")
      expect(await s.snapshot()).toEqual(before)
    } finally {
      await db.execute(sql`DROP TRIGGER test_reject_update ON updates; DROP FUNCTION test_reject_update();`)
    }
    const retried = await MessageModel.insertMessage({ chatId: s.chat.id, fromId: s.sender.id, randomId: 7n })
    expect(retried.message.messageId).toBe(1)
    expect(retried.update.seq).toBe(1)
    const after = await s.snapshot()
    expect(after.messages).toHaveLength(1)
    expect(after.updates).toHaveLength(1)
  })
})
