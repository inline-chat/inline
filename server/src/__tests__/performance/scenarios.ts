import assert from "node:assert/strict"
import { and, asc, eq, inArray } from "drizzle-orm"
import { MessageSendMode, type InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import * as S from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { UpdatesModel } from "@in/server/db/models/updates"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { getChats } from "@in/server/functions/messages.getChats"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { readMessages } from "@in/server/functions/messages.readMessages"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"
import { decryptMessage, encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { desktopPushSuppressionTracker } from "@in/server/modules/notifications/desktopPushSuppression"
import { cleanDatabase, testUtils } from "../setup"
import type { ScenarioSpec } from "./catalog"

export type PreparedOperation = { run(): Promise<void>; verify(): Promise<void> }

function checked<A>(run: () => Promise<A>, verify: (result: A) => Promise<void>): PreparedOperation {
  let result: A
  return { async run() { result = await run() }, async verify() { await verify(result) } }
}

const peer = (chatId: number): InputPeer => ({ type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } })
const text = "Backend benchmark message"

async function actors(count: number) {
  const users = await db.insert(S.users).values(Array.from({ length: count }, (_, i) => ({ email: `bench-${i}@example.test` }))).returning()
  const sender = users[0]!
  const { session } = await testUtils.createSessionForUser(sender.id, { clientType: "web" })
  return { users, sender, context: testUtils.functionContext({ userId: sender.id, sessionId: session.id }) }
}

async function dm() {
  const a = await actors(2)
  const [chat] = await db.insert(S.chats).values({ type: "private", minUserId: a.sender.id, maxUserId: a.users[1]!.id }).returning()
  assert(chat)
  await db.insert(S.dialogs).values(a.users.map((user, i) => ({
    userId: user.id, chatId: chat.id, peerUserId: a.users[1 - i]!.id, open: true, order: "a0",
  })))
  return { ...a, chat, peer: peer(chat.id) }
}

async function thread(size: number, reply: boolean) {
  const a = await actors(size + 1)
  const [space] = await db.insert(S.spaces).values({ name: "Benchmark space" }).returning()
  assert(space)
  await db.insert(S.members).values(a.users.map((user) => ({ userId: user.id, spaceId: space.id, role: "member" as const, canAccessPublicChats: true })))
  const [parent] = await db.insert(S.chats).values({
    type: "thread", spaceId: space.id, publicThread: true, messageIdCounter: 20, title: "Benchmark thread", isUntitled: false,
  }).returning()
  assert(parent)
  const dialogs = (chatId: number) => a.users.map((user) => ({
    userId: user.id, chatId, spaceId: space.id, followMode: "following" as const, open: true, order: "a0",
  }))
  await db.insert(S.dialogs).values(dialogs(parent.id))
  let chat = parent
  if (reply) {
    await seedMessages(parent.id, a.sender.id, 1)
    const [child] = await db.insert(S.chats).values({
      type: "thread", spaceId: space.id, publicThread: false, parentChatId: parent.id, parentMessageId: 1,
      messageIdCounter: 20, title: "Named reply thread", isUntitled: false,
    }).returning()
    assert(child)
    chat = child
    await db.insert(S.dialogs).values(dialogs(chat.id))
  }
  return { ...a, chat, parent, peer: peer(chat.id) }
}

async function seedMessages(chatId: number, fromId: number, count: number) {
  await db.insert(S.messages).values(Array.from({ length: count }, (_, i) => {
    const encrypted = encryptMessage(`Seed ${i + 1}`)
    return { chatId, fromId, messageId: i + 1, textEncrypted: encrypted.encrypted, textIv: encrypted.iv, textTag: encrypted.authTag }
  }))
  await db.update(S.chats).set({ lastMsgId: count, messageIdCounter: count }).where(eq(S.chats.id, chatId))
}

function journalMessage(chatId: number, fromId: number, randomId?: bigint) {
  const encrypted = encryptMessage(text)
  return MessageModel.insertMessage({ chatId, fromId, randomId, textEncrypted: encrypted.encrypted, textIv: encrypted.iv, textTag: encrypted.authTag })
}

async function verifySend(chatId: number, messageId: number, senderId: number, randomId: bigint) {
  const rows = await db.select().from(S.messages).where(eq(S.messages.chatId, chatId))
  assert.equal(rows.length, 1)
  assert.equal(rows[0]!.messageId, messageId)
  assert.equal(rows[0]!.fromId, senderId)
  assert.equal(rows[0]!.randomId, randomId)
  assert.equal(decryptMessage({ encrypted: rows[0]!.textEncrypted!, iv: rows[0]!.textIv!, authTag: rows[0]!.textTag! }), text)
  const journal = await db.select().from(S.updates).where(and(eq(S.updates.bucket, S.UpdateBucket.Chat), eq(S.updates.entityId, chatId)))
  assert.equal(journal.length, 1)
  assert.equal(journal[0]!.seq, 1)
  assert.equal(UpdatesModel.decrypt(journal[0]!).payload.update.oneofKind, "newMessage")
  const [chat] = await db.select().from(S.chats).where(eq(S.chats.id, chatId))
  assert.equal(chat?.lastMsgId, messageId)
  assert.equal(chat?.messageIdCounter, messageId)
  assert.equal(chat?.updateSeq, 1)
  const dialogs = await db.select().from(S.dialogs).where(eq(S.dialogs.chatId, chatId))
  assert(dialogs.every((dialog) => dialog.open && dialog.order))
}

/** Each iteration gets equivalent durable state and cold authorization/session
 * caches. IDs are intentionally fresh: accidental cross-scenario cache reuse must
 * not make a path appear cheap. Pool/JIT warmup is a separate runner concern. */
export async function prepareScenario(spec: ScenarioSpec): Promise<PreparedOperation> {
  await cleanDatabase()
  desktopPushSuppressionTracker.resetForTests()
  switch (spec.kind) {
    case "sendDm": {
      const s = await dm()
      const input = { peerId: s.peer, message: text, randomId: 91n, sendMode: MessageSendMode.MODE_SILENT }
      if (spec.variant === "closed") await db.update(S.dialogs).set({ open: false, order: null }).where(eq(S.dialogs.userId, s.users[1]!.id))
      if (spec.variant === "retry") await journalMessage(s.chat.id, s.sender.id, 91n)
      return checked(() => sendMessage(input, s.context), async (result) => {
        assert(result.updates.some((update) => update.update.oneofKind === "updateMessageId" && update.update.updateMessageId.randomId === 91n && update.update.updateMessageId.messageId === 1n))
        await verifySend(s.chat.id, 1, s.sender.id, 91n)
      })
    }
    case "sendThread": {
      const s = await thread(spec.size, spec.variant === "reply")
      return checked(() => sendMessage({ peerId: s.peer, message: text, randomId: 91n, sendMode: MessageSendMode.MODE_SILENT }, s.context), async (result) => {
        assert(result.updates.some((update) => update.update.oneofKind === "newMessage"))
        await verifySend(s.chat.id, 21, s.sender.id, 91n)
        if (spec.variant === "reply") {
          // A reply must keep the parent's durable reply projection in sync.
          const parentEvents = await db.select().from(S.updates).where(and(eq(S.updates.bucket, S.UpdateBucket.Chat), eq(S.updates.entityId, s.parent.id)))
          assert(parentEvents.some((event) => UpdatesModel.decrypt(event).payload.update.oneofKind === "editMessage"))
          const parentHistory = await getChatHistory({ peerId: peer(s.parent.id), limit: 1 }, s.context)
          assert.equal(parentHistory.messages[0]?.replies?.replyCount, 1)
        }
      })
    }
    case "getChats": {
      const a = await actors(spec.size + 1)
      const chats = await db.insert(S.chats).values(a.users.slice(1).map((user) => ({ type: "private" as const, minUserId: a.sender.id, maxUserId: user.id }))).returning()
      const orders = FractionalIndex.sequence(chats.length)
      await db.insert(S.dialogs).values(chats.map((chat, i) => ({ userId: a.sender.id, chatId: chat.id, peerUserId: a.users[i + 1]!.id, open: true, order: orders[i]! })))
      await db.insert(S.messages).values(chats.map((chat) => {
        const encrypted = encryptMessage(text)
        return { chatId: chat.id, fromId: chat.maxUserId!, messageId: 1, textEncrypted: encrypted.encrypted, textIv: encrypted.iv, textTag: encrypted.authTag }
      }))
      await db.update(S.chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(inArray(S.chats.id, chats.map((chat) => chat.id)))
      return checked(() => getChats({}, a.context), async (result) => {
        assert.deepEqual(result.chats.map((chat) => Number(chat.id)).sort((a, b) => a - b), chats.map((chat) => chat.id).sort((a, b) => a - b))
        assert.equal(result.dialogs.length, spec.size)
        assert.equal(result.messages.length, spec.size)
        assert(result.messages.every((message) => message.message === text && message.id === 1n))
        assert.equal(new Set(result.dialogs.map((dialog) => dialog.chatId)).size, spec.size)
      })
    }
    case "history": {
      const s = await dm()
      await seedMessages(s.chat.id, s.users[1]!.id, spec.size + 1)
      return checked(() => getChatHistory({ peerId: s.peer, mode: "older", beforeId: BigInt(spec.size + 1), limit: spec.size }, s.context), async (result) => {
        assert.deepEqual(result.messages.map((message) => message.id), Array.from({ length: spec.size }, (_, i) => BigInt(spec.size - i)))
        assert.deepEqual(result.messages.map((message) => message.message), Array.from({ length: spec.size }, (_, i) => `Seed ${spec.size - i}`))
      })
    }
    case "replay": {
      const s = await dm()
      await journalMessage(s.chat.id, s.sender.id)
      return checked(() => getUpdates({ bucket: { type: { oneofKind: "chat", chat: { peerId: s.peer } } }, startSeq: spec.variant === "empty" ? 1n : 0n, totalLimit: 0, seqEnd: 0n, limit: 0 }, s.context), async (result) => {
        assert.equal(result.seq, 1n)
        assert.equal(result.final, true)
        assert.equal(result.updates.length, spec.variant === "empty" ? 0 : 1)
        if (spec.variant !== "empty") {
          const update = result.updates[0]!.update
          assert.equal(update.oneofKind, "newMessage")
          if (update.oneofKind === "newMessage") assert.equal(update.newMessage.message?.message, text)
        }
      })
    }
    case "checkpoint": {
      const a = await actors(1)
      return checked(() => getUpdatesState({}, a.context), async (result) => {
        assert(result.date > 0n)
        assert.equal(result.seq, 0)
        assert.equal(result.updatesFound, false)
      })
    }
    case "enqueue": {
      const a = await actors(spec.size)
      // Reverse owner order exercises lock sorting without changing caller order.
      const inputs = [...a.users].reverse().map((user) => ({ userId: user.id, update: {
        oneofKind: "userMarkAsUnread" as const,
        userMarkAsUnread: { peerId: { type: { oneofKind: "user" as const, user: { userId: BigInt(user.id) } } }, unreadMark: true },
      } }))
      return checked(() => UserBucketUpdates.enqueueMany(inputs), async (result) => {
        assert.equal(result.length, inputs.length)
        const owners = await db.select().from(S.users).orderBy(asc(S.users.id))
        const journal = await db.select().from(S.updates).orderBy(asc(S.updates.entityId))
        assert.equal(journal.length, inputs.length)
        for (const [i, user] of a.users.entries()) {
          assert.equal(owners[i]!.updateSeq, 1)
          assert.equal(journal[i]!.entityId, user.id)
          assert.equal(journal[i]!.seq, 1)
          const payload = UpdatesModel.decrypt(journal[i]!).payload
          assert.equal(payload.update.oneofKind, "userMarkAsUnread")
          assert.equal(result[inputs.findIndex((input) => input.userId === user.id)]!.date.getTime(), journal[i]!.date.getTime())
        }
      })
    }
    case "dialog": {
      const s = await thread(spec.size, false)
      const userIds = s.users.slice(1).map((user) => user.id)
      const before = await db.select().from(S.dialogs).where(eq(S.dialogs.chatId, s.chat.id)).orderBy(asc(S.dialogs.id))
      return checked(() => setDialogOpenForUsers({ chat: s.chat, userIds, open: true, showInChatList: true }), async (result) => {
        assert.equal(result.dialogs.length, spec.size)
        assert.deepEqual(result.changedDialogs, [])
        assert.deepEqual(await db.select().from(S.dialogs).where(eq(S.dialogs.chatId, s.chat.id)).orderBy(asc(S.dialogs.id)), before)
        assert.equal((await db.select().from(S.updates)).length, 0)
      })
    }
    case "read": {
      const s = await dm()
      await seedMessages(s.chat.id, s.users[1]!.id, 1)
      if (spec.variant === "noop") await db.update(S.dialogs).set({ readInboxMaxId: 1 }).where(eq(S.dialogs.userId, s.sender.id))
      return checked(() => readMessages({ peer: s.peer, maxId: 1 }, s.context), async () => {
        const [dialog] = await db.select().from(S.dialogs).where(eq(S.dialogs.userId, s.sender.id))
        assert.equal(dialog?.readInboxMaxId, 1)
        assert.equal(dialog?.unreadMark, false)
        const journal = await db.select().from(S.updates).where(and(eq(S.updates.bucket, S.UpdateBucket.User), eq(S.updates.entityId, s.sender.id)))
        assert.equal(journal.length, spec.variant === "noop" ? 0 : 1)
      })
    }
  }
}
