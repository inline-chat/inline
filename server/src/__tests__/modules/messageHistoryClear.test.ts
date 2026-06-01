import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { clearChatHistoryData, clearSpaceHistoryData } from "@in/server/modules/historyClear/data"
import { asc, eq, inArray } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const CUTOFF = new Date("2026-01-15T12:00:00.000Z")
const OLDER = new Date("2026-01-01T12:00:00.000Z")
const OLD = new Date("2026-01-10T12:00:00.000Z")
const BOUNDARY = new Date(CUTOFF)
const RECENT = new Date("2026-01-20T12:00:00.000Z")

let nextId = 1

type TestCase = {
  name: string
  run: () => Promise<void>
}

async function user(label = "user") {
  return await testUtils.createUser(`history-clear-${label}-${nextId++}@example.com`)
}

async function space(label = "space") {
  const row = await testUtils.createSpace(`history-clear-${label}-${nextId++}`)
  if (!row) {
    throw new Error("Failed to create space")
  }
  return row
}

async function chat(input: {
  spaceId?: number | null
  title?: string
  createdBy?: number
  publicThread?: boolean
  parentChatId?: number
  parentMessageId?: number
}) {
  const [row] = await db
    .insert(schema.chats)
    .values({
      type: "thread",
      title: input.title ?? `chat-${nextId++}`,
      spaceId: input.spaceId ?? null,
      publicThread: input.publicThread ?? false,
      createdBy: input.createdBy ?? null,
      parentChatId: input.parentChatId,
      parentMessageId: input.parentMessageId,
    })
    .returning()

  if (!row) {
    throw new Error("Failed to create chat")
  }

  return row
}

async function msg(input: {
  chatId: number
  messageId: number
  fromId: number
  date?: Date
  text?: string
}) {
  await db.insert(schema.messages).values({
    chatId: input.chatId,
    messageId: input.messageId,
    fromId: input.fromId,
    date: input.date ?? RECENT,
    text: input.text ?? `message-${input.messageId}`,
  })
}

async function translation(chatId: number, messageId: number, language = `lang-${nextId++}`) {
  await db.insert(schema.translations).values({
    chatId,
    messageId,
    language,
  })
}

async function participant(chatId: number, userId: number) {
  await db.insert(schema.chatParticipants).values({ chatId, userId })
}

async function dialog(chatId: number, userId: number, spaceId?: number | null) {
  await db.insert(schema.dialogs).values({ chatId, userId, spaceId: spaceId ?? null })
}

async function setLast(chatId: number, lastMsgId: number | null) {
  await db.update(schema.chats).set({ lastMsgId }).where(eq(schema.chats.id, chatId))
}

async function clearChat(chatId: number, options?: { beforeDate?: Date; deleteReplyThreads?: boolean }) {
  return await db.transaction((tx) =>
    clearChatHistoryData(tx, {
      chatId,
      beforeDate: options?.beforeDate,
      deleteReplyThreads: options?.deleteReplyThreads ?? false,
    }),
  )
}

async function clearSpace(spaceId: number, options?: { beforeDate?: Date; deleteReplyThreads?: boolean }) {
  return await db.transaction((tx) =>
    clearSpaceHistoryData(tx, {
      spaceId,
      beforeDate: options?.beforeDate,
      deleteReplyThreads: options?.deleteReplyThreads ?? false,
    }),
  )
}

async function messageIds(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ messageId: schema.messages.messageId })
    .from(schema.messages)
    .where(eq(schema.messages.chatId, chatId))
    .orderBy(asc(schema.messages.messageId))

  return rows.map((row) => row.messageId)
}

async function messagesByChat(chatIds: number[]): Promise<Record<number, number[]>> {
  if (chatIds.length === 0) {
    return {}
  }

  const rows = await db
    .select({ chatId: schema.messages.chatId, messageId: schema.messages.messageId })
    .from(schema.messages)
    .where(inArray(schema.messages.chatId, chatIds))
    .orderBy(asc(schema.messages.chatId), asc(schema.messages.messageId))

  const result: Record<number, number[]> = {}
  for (const chatId of chatIds) {
    result[chatId] = []
  }
  for (const row of rows) {
    result[row.chatId]?.push(row.messageId)
  }
  return result
}

async function translationIds(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ messageId: schema.translations.messageId })
    .from(schema.translations)
    .where(eq(schema.translations.chatId, chatId))
    .orderBy(asc(schema.translations.messageId))

  return rows.map((row) => row.messageId)
}

async function getChat(chatId: number) {
  const [row] = await db.select().from(schema.chats).where(eq(schema.chats.id, chatId)).limit(1)
  return row
}

async function lastMsgId(chatId: number): Promise<number | null | undefined> {
  return (await getChat(chatId))?.lastMsgId
}

async function participantIds(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: schema.chatParticipants.userId })
    .from(schema.chatParticipants)
    .where(eq(schema.chatParticipants.chatId, chatId))
    .orderBy(asc(schema.chatParticipants.userId))

  return rows.map((row) => row.userId)
}

async function dialogUserIds(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: schema.dialogs.userId })
    .from(schema.dialogs)
    .where(eq(schema.dialogs.chatId, chatId))
    .orderBy(asc(schema.dialogs.userId))

  return rows.map((row) => row.userId)
}

async function baseChat() {
  const owner = await user("owner")
  const parent = await chat({ createdBy: owner.id })
  return { owner, parent }
}

async function baseSpace() {
  const owner = await user("owner")
  const targetSpace = await space("target")
  const otherSpace = await space("other")
  return { owner, targetSpace, otherSpace }
}

async function replyThread(input: {
  parent: schema.DbChat
  parentMessageId: number
  createdBy: number
  spaceId?: number | null
  title?: string
}) {
  return await chat({
    spaceId: input.spaceId === undefined ? input.parent.spaceId : input.spaceId,
    title: input.title,
    createdBy: input.createdBy,
    parentChatId: input.parent.id,
    parentMessageId: input.parentMessageId,
  })
}

const chatRetentionCases: TestCase[] = [
  {
    name: "chat clear all deletes all target messages",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      await setLast(parent.id, 2)

      const result = await clearChat(parent.id)

      expect(result.lastMsgId).toBeNull()
      expect(await messageIds(parent.id)).toEqual([])
      expect(await lastMsgId(parent.id)).toBeNull()
    },
  },
  {
    name: "chat clear all handles an empty chat",
    run: async () => {
      const { parent } = await baseChat()

      const result = await clearChat(parent.id)

      expect(result.lastMsgId).toBeNull()
      expect(await messageIds(parent.id)).toEqual([])
    },
  },
  {
    name: "chat clear all leaves another chat untouched",
    run: async () => {
      const { owner, parent } = await baseChat()
      const other = await chat({ createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: other.id, messageId: 1, fromId: owner.id, date: OLD })
      await setLast(parent.id, 1)
      await setLast(other.id, 1)

      await clearChat(parent.id)

      expect(await messageIds(parent.id)).toEqual([])
      expect(await messageIds(other.id)).toEqual([1])
      expect(await lastMsgId(other.id)).toBe(1)
    },
  },
  {
    name: "chat retention deletes messages older than cutoff",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      await setLast(parent.id, 2)

      const result = await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(result.lastMsgId).toBe(2)
      expect(await messageIds(parent.id)).toEqual([2])
    },
  },
  {
    name: "chat retention keeps messages exactly at cutoff",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: BOUNDARY })
      await setLast(parent.id, 1)

      const result = await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(result.lastMsgId).toBe(1)
      expect(await messageIds(parent.id)).toEqual([1])
    },
  },
  {
    name: "chat retention keeps messages newer than cutoff",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: RECENT })
      await setLast(parent.id, 1)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await messageIds(parent.id)).toEqual([1])
      expect(await lastMsgId(parent.id)).toBe(1)
    },
  },
  {
    name: "chat retention deletes multiple old messages",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLDER })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 3, fromId: owner.id, date: RECENT })
      await setLast(parent.id, 3)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await messageIds(parent.id)).toEqual([3])
    },
  },
  {
    name: "chat retention keeps all messages when none are old",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: BOUNDARY })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      await setLast(parent.id, 2)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await messageIds(parent.id)).toEqual([1, 2])
      expect(await lastMsgId(parent.id)).toBe(2)
    },
  },
  {
    name: "chat retention deletes all messages when every message is old",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLDER })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: OLD })
      await setLast(parent.id, 2)

      const result = await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(result.lastMsgId).toBeNull()
      expect(await messageIds(parent.id)).toEqual([])
      expect(await lastMsgId(parent.id)).toBeNull()
    },
  },
  {
    name: "chat retention refreshes last message when highest id is deleted",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: RECENT })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 3, fromId: owner.id, date: OLD })
      await setLast(parent.id, 3)

      const result = await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(result.lastMsgId).toBe(1)
      expect(await lastMsgId(parent.id)).toBe(1)
    },
  },
  {
    name: "chat retention refreshes last message by remaining message id",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: RECENT })
      await msg({ chatId: parent.id, messageId: 4, fromId: owner.id, date: RECENT })
      await msg({ chatId: parent.id, messageId: 5, fromId: owner.id, date: OLD })
      await setLast(parent.id, 5)

      const result = await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(result.lastMsgId).toBe(4)
      expect(await messageIds(parent.id)).toEqual([1, 4])
    },
  },
  {
    name: "chat retention clears last message when the only message is deleted",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 9, fromId: owner.id, date: OLD })
      await setLast(parent.id, 9)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await lastMsgId(parent.id)).toBeNull()
    },
  },
  {
    name: "chat retention sets last message when initial last message is null",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })

      const result = await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(result.lastMsgId).toBe(2)
      expect(await lastMsgId(parent.id)).toBe(2)
    },
  },
  {
    name: "chat retention deletes translations for deleted messages",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await translation(parent.id, 1)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await translationIds(parent.id)).toEqual([])
    },
  },
  {
    name: "chat retention keeps translations for recent messages",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      await translation(parent.id, 1)
      await translation(parent.id, 2)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await translationIds(parent.id)).toEqual([2])
    },
  },
  {
    name: "chat retention keeps translations for messages exactly at cutoff",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: BOUNDARY })
      await translation(parent.id, 1)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await translationIds(parent.id)).toEqual([1])
    },
  },
  {
    name: "chat retention keeps another chat translation with the same message id",
    run: async () => {
      const { owner, parent } = await baseChat()
      const other = await chat({ createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: other.id, messageId: 1, fromId: owner.id, date: OLD })
      await translation(parent.id, 1)
      await translation(other.id, 1)

      await clearChat(parent.id, { beforeDate: CUTOFF })

      expect(await translationIds(parent.id)).toEqual([])
      expect(await translationIds(other.id)).toEqual([1])
    },
  },
  {
    name: "chat retention is idempotent for an already cleared chat",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await setLast(parent.id, 1)

      await clearChat(parent.id)
      const result = await clearChat(parent.id)

      expect(result.lastMsgId).toBeNull()
      expect(await messageIds(parent.id)).toEqual([])
    },
  },
]

const chatReplyCases: TestCase[] = [
  {
    name: "chat orphaning clears direct reply-thread anchors",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })

      const result = await clearChat(parent.id, { deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBeNull()
      expect(result.orphanedChatIds).toEqual([child.id])
      expect(result.deletedChatIds).toEqual([])
      expect(result.detachedChatIds).toEqual([])
    },
  },
  {
    name: "chat orphaning only clears old anchors in a retention range",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      const oldChild = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      const recentChild = await replyThread({ parent, parentMessageId: 2, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect((await getChat(oldChild.id))?.parentMessageId).toBeNull()
      expect((await getChat(recentChild.id))?.parentMessageId).toBe(2)
    },
  },
  {
    name: "chat orphaning keeps anchors exactly at cutoff",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: BOUNDARY })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "chat orphaning keeps recent anchors",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: RECENT })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "chat orphaning keeps child messages",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: RECENT })
      await setLast(child.id, 1)

      await clearChat(parent.id, { deleteReplyThreads: false })

      expect(await messageIds(child.id)).toEqual([1])
      expect(await lastMsgId(child.id)).toBe(1)
    },
  },
  {
    name: "chat orphaning keeps child translations",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: RECENT })
      await translation(child.id, 1)

      await clearChat(parent.id, { deleteReplyThreads: false })

      expect(await translationIds(child.id)).toEqual([1])
    },
  },
  {
    name: "chat orphaning keeps child participants",
    run: async () => {
      const { owner, parent } = await baseChat()
      const member = await user("member")
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await participant(child.id, member.id)

      await clearChat(parent.id, { deleteReplyThreads: false })

      expect(await participantIds(child.id)).toEqual([member.id])
    },
  },
  {
    name: "chat orphaning keeps child dialogs",
    run: async () => {
      const { owner, parent } = await baseChat()
      const member = await user("member")
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await dialog(child.id, member.id)

      await clearChat(parent.id, { deleteReplyThreads: false })

      expect(await dialogUserIds(child.id)).toEqual([member.id])
    },
  },
  {
    name: "chat orphaning leaves unrelated reply threads untouched",
    run: async () => {
      const { owner, parent } = await baseChat()
      const otherParent = await chat({ createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: otherParent.id, messageId: 1, fromId: owner.id, date: OLD })
      const otherChild = await replyThread({ parent: otherParent, parentMessageId: 1, createdBy: owner.id })

      await clearChat(parent.id, { deleteReplyThreads: false })

      expect((await getChat(otherChild.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "chat orphaning does not mutate nested reply anchors",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: RECENT })
      const grandchild = await replyThread({ parent: child, parentMessageId: 1, createdBy: owner.id })

      await clearChat(parent.id, { deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBeNull()
      expect((await getChat(grandchild.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "chat reply deletion removes direct reply threads",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })

      const result = await clearChat(parent.id, { deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeUndefined()
      expect(result.deletedChatIds).toEqual([child.id])
      expect(result.orphanedChatIds).toEqual([])
      expect(result.detachedChatIds).toEqual([])
    },
  },
  {
    name: "chat reply deletion reports inherited and direct recipients before deleting chats",
    run: async () => {
      const { owner, parent } = await baseChat()
      const parentMember = await user("parent-member")
      const childMember = await user("child-member")
      await participant(parent.id, owner.id)
      await participant(parent.id, parentMember.id)
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await participant(child.id, childMember.id)

      const result = await clearChat(parent.id, { deleteReplyThreads: true })

      expect(result.deletedChatIds).toEqual([child.id])
      expect(result.deletedChats.map((row) => row.chat.id)).toEqual([child.id])
      expect(result.deletedChats[0]?.userIds.sort((a, b) => a - b)).toEqual(
        [owner.id, parentMember.id, childMember.id].sort((a, b) => a - b),
      )
    },
  },
  {
    name: "chat reply deletion removes nested reply subtrees",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: RECENT })
      const grandchild = await replyThread({ parent: child, parentMessageId: 1, createdBy: owner.id })

      await clearChat(parent.id, { deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeUndefined()
      expect(await getChat(grandchild.id)).toBeUndefined()
    },
  },
  {
    name: "chat reply deletion removes child messages",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: RECENT })

      await clearChat(parent.id, { deleteReplyThreads: true })

      expect(await messageIds(child.id)).toEqual([])
    },
  },
  {
    name: "chat reply deletion removes child translations",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: RECENT })
      await translation(child.id, 1)

      await clearChat(parent.id, { deleteReplyThreads: true })

      expect(await translationIds(child.id)).toEqual([])
    },
  },
  {
    name: "chat reply deletion removes child participants and dialogs",
    run: async () => {
      const { owner, parent } = await baseChat()
      const member = await user("member")
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      await participant(child.id, member.id)
      await dialog(child.id, member.id)

      await clearChat(parent.id, { deleteReplyThreads: true })

      expect(await participantIds(child.id)).toEqual([])
      expect(await dialogUserIds(child.id)).toEqual([])
    },
  },
  {
    name: "chat reply deletion removes only old-anchor threads in a range",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      const oldChild = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      const recentChild = await replyThread({ parent, parentMessageId: 2, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect(await getChat(oldChild.id)).toBeUndefined()
      expect((await getChat(recentChild.id))?.parentMessageId).toBe(2)
    },
  },
  {
    name: "chat reply deletion keeps cutoff-anchor threads",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: BOUNDARY })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "chat reply deletion keeps recent-anchor threads",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: RECENT })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "chat reply deletion removes multiple deleted-anchor threads",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: OLD })
      const childA = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      const childB = await replyThread({ parent, parentMessageId: 2, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect(await getChat(childA.id)).toBeUndefined()
      expect(await getChat(childB.id)).toBeUndefined()
    },
  },
  {
    name: "chat reply deletion can delete one child while keeping another",
    run: async () => {
      const { owner, parent } = await baseChat()
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      const oldChild = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id })
      const recentChild = await replyThread({ parent, parentMessageId: 2, createdBy: owner.id })

      await clearChat(parent.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect(await getChat(oldChild.id)).toBeUndefined()
      expect(await getChat(recentChild.id)).toBeDefined()
    },
  },
]

const spaceRetentionCases: TestCase[] = [
  {
    name: "space clear all deletes messages in every space chat",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const chatA = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const chatB = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: chatA.id, messageId: 1, fromId: owner.id })
      await msg({ chatId: chatB.id, messageId: 1, fromId: owner.id })
      await setLast(chatA.id, 1)
      await setLast(chatB.id, 1)

      await clearSpace(targetSpace.id)

      expect(await messagesByChat([chatA.id, chatB.id])).toEqual({ [chatA.id]: [], [chatB.id]: [] })
      expect(await lastMsgId(chatA.id)).toBeNull()
      expect(await lastMsgId(chatB.id)).toBeNull()
    },
  },
  {
    name: "space clear all leaves another space untouched",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const other = await chat({ spaceId: otherSpace.id, createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 1, fromId: owner.id })
      await msg({ chatId: other.id, messageId: 1, fromId: owner.id })
      await setLast(target.id, 1)
      await setLast(other.id, 1)

      await clearSpace(targetSpace.id)

      expect(await messageIds(target.id)).toEqual([])
      expect(await messageIds(other.id)).toEqual([1])
      expect(await lastMsgId(other.id)).toBe(1)
    },
  },
  {
    name: "space clear all leaves no-space chats untouched",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const home = await chat({ createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 1, fromId: owner.id })
      await msg({ chatId: home.id, messageId: 1, fromId: owner.id })

      await clearSpace(targetSpace.id)

      expect(await messageIds(target.id)).toEqual([])
      expect(await messageIds(home.id)).toEqual([1])
    },
  },
  {
    name: "space retention deletes old messages in every space chat",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const chatA = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const chatB = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: chatA.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: chatA.id, messageId: 2, fromId: owner.id, date: RECENT })
      await msg({ chatId: chatB.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: chatB.id, messageId: 2, fromId: owner.id, date: RECENT })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await messagesByChat([chatA.id, chatB.id])).toEqual({ [chatA.id]: [2], [chatB.id]: [2] })
    },
  },
  {
    name: "space retention keeps recent messages in every chat",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const chatA = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const chatB = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: chatA.id, messageId: 1, fromId: owner.id, date: RECENT })
      await msg({ chatId: chatB.id, messageId: 1, fromId: owner.id, date: RECENT })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await messagesByChat([chatA.id, chatB.id])).toEqual({ [chatA.id]: [1], [chatB.id]: [1] })
    },
  },
  {
    name: "space retention keeps messages exactly at cutoff",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 1, fromId: owner.id, date: BOUNDARY })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await messageIds(target.id)).toEqual([1])
    },
  },
  {
    name: "space retention refreshes last message id per chat",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const chatA = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const chatB = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: chatA.id, messageId: 1, fromId: owner.id, date: RECENT })
      await msg({ chatId: chatA.id, messageId: 2, fromId: owner.id, date: OLD })
      await msg({ chatId: chatB.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: chatB.id, messageId: 3, fromId: owner.id, date: RECENT })
      await setLast(chatA.id, 2)
      await setLast(chatB.id, 3)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await lastMsgId(chatA.id)).toBe(1)
      expect(await lastMsgId(chatB.id)).toBe(3)
    },
  },
  {
    name: "space retention clears last message ids when all messages are removed",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const chatA = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const chatB = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: chatA.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: chatB.id, messageId: 1, fromId: owner.id, date: OLD })
      await setLast(chatA.id, 1)
      await setLast(chatB.id, 1)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await lastMsgId(chatA.id)).toBeNull()
      expect(await lastMsgId(chatB.id)).toBeNull()
    },
  },
  {
    name: "space retention deletes translations in all target chats",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const chatA = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const chatB = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: chatA.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: chatB.id, messageId: 1, fromId: owner.id, date: OLD })
      await translation(chatA.id, 1)
      await translation(chatB.id, 1)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await translationIds(chatA.id)).toEqual([])
      expect(await translationIds(chatB.id)).toEqual([])
    },
  },
  {
    name: "space retention keeps translations for recent target messages",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: target.id, messageId: 2, fromId: owner.id, date: RECENT })
      await translation(target.id, 1)
      await translation(target.id, 2)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await translationIds(target.id)).toEqual([2])
    },
  },
  {
    name: "space retention keeps translations in another space",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const other = await chat({ spaceId: otherSpace.id, createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: other.id, messageId: 1, fromId: owner.id, date: OLD })
      await translation(target.id, 1)
      await translation(other.id, 1)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await translationIds(target.id)).toEqual([])
      expect(await translationIds(other.id)).toEqual([1])
    },
  },
  {
    name: "space retention keeps translations in no-space chats",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const home = await chat({ createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: home.id, messageId: 1, fromId: owner.id, date: OLD })
      await translation(target.id, 1)
      await translation(home.id, 1)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await translationIds(target.id)).toEqual([])
      expect(await translationIds(home.id)).toEqual([1])
    },
  },
  {
    name: "space clear handles an empty space",
    run: async () => {
      const { targetSpace } = await baseSpace()

      await expect(clearSpace(targetSpace.id)).resolves.toEqual({
        deletedChatIds: [],
        orphanedChatIds: [],
        detachedChatIds: [],
        deletedChats: [],
        detachedAccessLosses: [],
      })
    },
  },
  {
    name: "space clear is idempotent",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 1, fromId: owner.id })
      await setLast(target.id, 1)

      await clearSpace(targetSpace.id)
      await clearSpace(targetSpace.id)

      expect(await messageIds(target.id)).toEqual([])
      expect(await lastMsgId(target.id)).toBeNull()
    },
  },
  {
    name: "space clear handles public and private space threads alike",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const publicChat = await chat({ spaceId: targetSpace.id, createdBy: owner.id, publicThread: true })
      const privateChat = await chat({ spaceId: targetSpace.id, createdBy: owner.id, publicThread: false })
      await msg({ chatId: publicChat.id, messageId: 1, fromId: owner.id })
      await msg({ chatId: privateChat.id, messageId: 1, fromId: owner.id })

      await clearSpace(targetSpace.id)

      expect(await messagesByChat([publicChat.id, privateChat.id])).toEqual({
        [publicChat.id]: [],
        [privateChat.id]: [],
      })
    },
  },
  {
    name: "space retention only deletes duplicate message ids in the target space",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const target = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const other = await chat({ spaceId: otherSpace.id, createdBy: owner.id })
      await msg({ chatId: target.id, messageId: 7, fromId: owner.id, date: OLD })
      await msg({ chatId: other.id, messageId: 7, fromId: owner.id, date: OLD })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF })

      expect(await messageIds(target.id)).toEqual([])
      expect(await messageIds(other.id)).toEqual([7])
    },
  },
]

const spaceReplyCases: TestCase[] = [
  {
    name: "space orphaning clears direct reply-thread anchors",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBeNull()
    },
  },
  {
    name: "space orphaning only clears old anchors in a range",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      const oldChild = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      const recentChild = await replyThread({ parent, parentMessageId: 2, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect((await getChat(oldChild.id))?.parentMessageId).toBeNull()
      expect((await getChat(recentChild.id))?.parentMessageId).toBe(2)
    },
  },
  {
    name: "space orphaning keeps cutoff anchors",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: BOUNDARY })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "space orphaning keeps recent anchors",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: RECENT })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "space orphaning leaves another space reply thread untouched",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const targetParent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const otherParent = await chat({ spaceId: otherSpace.id, createdBy: owner.id })
      await msg({ chatId: targetParent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: otherParent.id, messageId: 1, fromId: owner.id, date: OLD })
      const otherChild = await replyThread({ parent: otherParent, parentMessageId: 1, createdBy: owner.id, spaceId: otherSpace.id })

      await clearSpace(targetSpace.id, { deleteReplyThreads: false })

      expect((await getChat(otherChild.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "space orphaning detaches external reply threads anchored to cleared messages",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const externalChild = await replyThread({
        parent,
        parentMessageId: 1,
        createdBy: owner.id,
        spaceId: otherSpace.id,
      })
      await msg({ chatId: externalChild.id, messageId: 1, fromId: owner.id, date: OLD })

      await clearSpace(targetSpace.id, { deleteReplyThreads: false })

      const retained = await getChat(externalChild.id)
      expect(retained).toBeDefined()
      expect(retained?.parentChatId).toBeNull()
      expect(retained?.parentMessageId).toBeNull()
      expect(await messageIds(externalChild.id)).toEqual([1])
    },
  },
  {
    name: "space orphaning reports users who lose access to detached external reply threads",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const targetMember = await user("target-member")
      const otherMember = await user("other-member")
      await db.insert(schema.members).values([
        { spaceId: targetSpace.id, userId: owner.id, role: "owner", canAccessPublicChats: true },
        { spaceId: targetSpace.id, userId: targetMember.id, role: "member", canAccessPublicChats: true },
        { spaceId: otherSpace.id, userId: otherMember.id, role: "member", canAccessPublicChats: true },
      ])
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id, publicThread: true })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const externalChild = await replyThread({
        parent,
        parentMessageId: 1,
        createdBy: otherMember.id,
        spaceId: otherSpace.id,
      })

      const result = await clearSpace(targetSpace.id, { deleteReplyThreads: false })

      expect(result.detachedChatIds).toEqual([externalChild.id])
      expect(result.detachedAccessLosses).toEqual([
        {
          chatId: externalChild.id,
          userIds: [owner.id, targetMember.id].sort((a, b) => a - b),
        },
      ])
    },
  },
  {
    name: "space orphaning ignores target-space child anchored to another space",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const otherParent = await chat({ spaceId: otherSpace.id, createdBy: owner.id })
      await msg({ chatId: otherParent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent: otherParent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { deleteReplyThreads: false })

      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "space reply deletion removes direct reply threads",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      const result = await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeUndefined()
      expect(result.deletedChatIds).toEqual([child.id])
      expect(result.orphanedChatIds).toEqual([])
      expect(result.detachedChatIds).toEqual([])
    },
  },
  {
    name: "space reply deletion reports public inherited and direct recipients before deleting chats",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const member = await user("member")
      const privateMember = await user("private-member")
      await db.insert(schema.members).values([
        { spaceId: targetSpace.id, userId: owner.id, role: "owner", canAccessPublicChats: true },
        { spaceId: targetSpace.id, userId: member.id, role: "member", canAccessPublicChats: true },
      ])
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id, publicThread: true })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      await participant(child.id, privateMember.id)

      const result = await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      expect(result.deletedChatIds).toEqual([child.id])
      expect(result.deletedChats.map((row) => row.chat.id)).toEqual([child.id])
      expect(result.deletedChats[0]?.userIds.sort((a, b) => a - b)).toEqual(
        [owner.id, member.id, privateMember.id].sort((a, b) => a - b),
      )
    },
  },
  {
    name: "space reply deletion removes nested reply subtrees",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: OLD })
      const grandchild = await replyThread({ parent: child, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeUndefined()
      expect(await getChat(grandchild.id)).toBeUndefined()
    },
  },
  {
    name: "space reply deletion removes child participants dialogs and translations",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const member = await user("member")
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: OLD })
      await translation(child.id, 1)
      await participant(child.id, member.id)
      await dialog(child.id, member.id, targetSpace.id)

      await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      expect(await translationIds(child.id)).toEqual([])
      expect(await participantIds(child.id)).toEqual([])
      expect(await dialogUserIds(child.id)).toEqual([])
    },
  },
  {
    name: "space reply deletion only deletes old-anchor threads in a range",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: RECENT })
      const oldChild = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      const recentChild = await replyThread({ parent, parentMessageId: 2, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect(await getChat(oldChild.id)).toBeUndefined()
      expect(await getChat(recentChild.id)).toBeDefined()
    },
  },
  {
    name: "space reply deletion keeps cutoff-anchor threads",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: BOUNDARY })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeDefined()
    },
  },
  {
    name: "space reply deletion keeps recent-anchor threads",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: RECENT })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeDefined()
    },
  },
  {
    name: "space reply deletion removes multiple deleted-anchor threads",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: parent.id, messageId: 2, fromId: owner.id, date: OLD })
      const childA = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      const childB = await replyThread({ parent, parentMessageId: 2, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: true })

      expect(await getChat(childA.id)).toBeUndefined()
      expect(await getChat(childB.id)).toBeUndefined()
    },
  },
  {
    name: "space reply deletion leaves no-space reply threads untouched",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const targetParent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      const homeParent = await chat({ createdBy: owner.id })
      await msg({ chatId: targetParent.id, messageId: 1, fromId: owner.id, date: OLD })
      await msg({ chatId: homeParent.id, messageId: 1, fromId: owner.id, date: OLD })
      const homeChild = await replyThread({ parent: homeParent, parentMessageId: 1, createdBy: owner.id, spaceId: null })

      await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      expect(await getChat(homeChild.id)).toBeDefined()
      expect((await getChat(homeChild.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "space reply deletion detaches external reply threads anchored to cleared messages",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const externalChild = await replyThread({
        parent,
        parentMessageId: 1,
        createdBy: owner.id,
        spaceId: otherSpace.id,
      })
      await msg({ chatId: externalChild.id, messageId: 1, fromId: owner.id, date: OLD })

      const result = await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      const retained = await getChat(externalChild.id)
      expect(retained).toBeDefined()
      expect(retained?.parentChatId).toBeNull()
      expect(retained?.parentMessageId).toBeNull()
      expect(await messageIds(externalChild.id)).toEqual([1])
      expect(result.detachedChatIds).toEqual([externalChild.id])
    },
  },
  {
    name: "space reply deletion detaches no-space reply threads anchored to cleared messages",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const homeChild = await replyThread({
        parent,
        parentMessageId: 1,
        createdBy: owner.id,
        spaceId: null,
      })
      await msg({ chatId: homeChild.id, messageId: 1, fromId: owner.id, date: OLD })

      await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      const retained = await getChat(homeChild.id)
      expect(retained).toBeDefined()
      expect(retained?.parentChatId).toBeNull()
      expect(retained?.parentMessageId).toBeNull()
      expect(await messageIds(homeChild.id)).toEqual([1])
    },
  },
  {
    name: "space reply deletion ignores target-space child anchored to another space",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const otherParent = await chat({ spaceId: otherSpace.id, createdBy: owner.id })
      await msg({ chatId: otherParent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent: otherParent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })

      await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeDefined()
      expect((await getChat(child.id))?.parentMessageId).toBe(1)
    },
  },
  {
    name: "space reply deletion detaches cross-space descendants instead of deleting them",
    run: async () => {
      const { owner, targetSpace, otherSpace } = await baseSpace()
      const targetMember = await user("target-member")
      await db.insert(schema.members).values([
        { spaceId: targetSpace.id, userId: owner.id, role: "owner", canAccessPublicChats: true },
        { spaceId: targetSpace.id, userId: targetMember.id, role: "member", canAccessPublicChats: true },
      ])
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id, publicThread: true })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: OLD })
      const grandchild = await replyThread({ parent: child, parentMessageId: 1, createdBy: owner.id, spaceId: otherSpace.id })

      const result = await clearSpace(targetSpace.id, { deleteReplyThreads: true })

      expect(await getChat(child.id)).toBeUndefined()
      const retained = await getChat(grandchild.id)
      expect(retained).toBeDefined()
      expect(retained?.parentChatId).toBeNull()
      expect(retained?.parentMessageId).toBeNull()
      expect(result.detachedChatIds).toEqual([grandchild.id])
      expect(result.detachedAccessLosses).toEqual([
        {
          chatId: grandchild.id,
          userIds: [owner.id, targetMember.id].sort((a, b) => a - b),
        },
      ])
    },
  },
  {
    name: "space orphaning still clears old child messages inside the space",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: OLD })
      await setLast(child.id, 1)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect(await getChat(child.id)).toBeDefined()
      expect((await getChat(child.id))?.parentMessageId).toBeNull()
      expect(await messageIds(child.id)).toEqual([])
      expect(await lastMsgId(child.id)).toBeNull()
    },
  },
  {
    name: "space orphaning keeps recent child messages inside the space",
    run: async () => {
      const { owner, targetSpace } = await baseSpace()
      const parent = await chat({ spaceId: targetSpace.id, createdBy: owner.id })
      await msg({ chatId: parent.id, messageId: 1, fromId: owner.id, date: OLD })
      const child = await replyThread({ parent, parentMessageId: 1, createdBy: owner.id, spaceId: targetSpace.id })
      await msg({ chatId: child.id, messageId: 1, fromId: owner.id, date: RECENT })
      await setLast(child.id, 1)

      await clearSpace(targetSpace.id, { beforeDate: CUTOFF, deleteReplyThreads: false })

      expect(await getChat(child.id)).toBeDefined()
      expect(await messageIds(child.id)).toEqual([1])
      expect(await lastMsgId(child.id)).toBe(1)
    },
  },
]

describe("message history clear data module", () => {
  setupTestLifecycle()

  for (const item of chatRetentionCases) {
    test(item.name, item.run)
  }

  for (const item of chatReplyCases) {
    test(item.name, item.run)
  }

  for (const item of spaceRetentionCases) {
    test(item.name, item.run)
  }

  for (const item of spaceReplyCases) {
    test(item.name, item.run)
  }
})
