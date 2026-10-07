import { expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { dialogs, messages } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "../setup"

setupTestLifecycle()

test("batch unread state preserves recipient marks, zero counts and unread eligibility", async () => {
  const viewer = await testUtils.createUser("unread-viewer@example.test")
  const author = await testUtils.createUser("unread-author@example.test")
  const populated = await testUtils.createTestChat()
  const read = await testUtils.createTestChat()
  const empty = await testUtils.createTestChat()
  const missingDialog = await testUtils.createTestChat()
  await db.insert(dialogs).values([
    { userId: viewer.id, chatId: populated.id, readInboxMaxId: 1, unreadMark: null },
    { userId: viewer.id, chatId: read.id, readInboxMaxId: 1, unreadMark: true },
    { userId: viewer.id, chatId: empty.id, unreadMark: true },
    { userId: author.id, chatId: populated.id, readInboxMaxId: 6, unreadMark: true },
    { userId: author.id, chatId: missingDialog.id, unreadMark: true },
  ])
  await db.insert(messages).values([
    { chatId: populated.id, fromId: author.id, messageId: 1 },
    { chatId: populated.id, fromId: author.id, messageId: 2 },
    { chatId: populated.id, fromId: viewer.id, messageId: 3 },
    { chatId: populated.id, fromId: author.id, messageId: 4, countsAsUnread: false },
    { chatId: populated.id, fromId: author.id, messageId: 5, systemMessageEncrypted: Buffer.from("system") },
    { chatId: populated.id, fromId: author.id, messageId: 6 },
    { chatId: read.id, fromId: author.id, messageId: 1 },
    { chatId: missingDialog.id, fromId: author.id, messageId: 1 },
  ])

  expect(await DialogsModel.getBatchUnreadCounts({
    userId: viewer.id,
    chatIds: [empty.id, populated.id, read.id, missingDialog.id, populated.id],
  })).toEqual([
    { chatId: empty.id, unreadCount: 0, unreadMark: true },
    { chatId: populated.id, unreadCount: 2, unreadMark: false },
    { chatId: read.id, unreadCount: 0, unreadMark: true },
    { chatId: missingDialog.id, unreadCount: 0, unreadMark: false },
    { chatId: populated.id, unreadCount: 2, unreadMark: false },
  ])
  expect(await DialogsModel.getBatchUnreadCounts({ userId: author.id, chatIds: [populated.id] }))
    .toEqual([{ chatId: populated.id, unreadCount: 0, unreadMark: true }])
  expect(await DialogsModel.getBatchUnreadCounts({ userId: viewer.id, chatIds: [] })).toEqual([])

  // A null read boundary starts at zero, rather than hiding all messages.
  await db.update(dialogs).set({ readInboxMaxId: null }).where(eq(dialogs.chatId, populated.id))
  expect(await DialogsModel.getBatchUnreadCounts({ userId: viewer.id, chatIds: [populated.id] }))
    .toEqual([{ chatId: populated.id, unreadCount: 3, unreadMark: false }])
})

test("batch unread state uses the caller's transaction for both count and mark", async () => {
  const viewer = await testUtils.createUser("unread-tx-viewer@example.test")
  const author = await testUtils.createUser("unread-tx-author@example.test")
  const chat = await testUtils.createTestChat()
  const [dialog] = await db.insert(dialogs).values({ userId: viewer.id, chatId: chat.id }).returning()
  if (!dialog) throw new Error("Missing dialog")
  await db.insert(messages).values({ chatId: chat.id, fromId: author.id, messageId: 1 })

  await db.transaction(async (tx) => {
    await tx.update(dialogs).set({ readInboxMaxId: 1, unreadMark: true }).where(eq(dialogs.id, dialog.id))
    expect(await DialogsModel.getBatchUnreadCounts({ userId: viewer.id, chatIds: [chat.id], tx }))
      .toEqual([{ chatId: chat.id, unreadCount: 0, unreadMark: true }])
    expect(await DialogsModel.getBatchUnreadCounts({ userId: viewer.id, chatIds: [chat.id] }))
      .toEqual([{ chatId: chat.id, unreadCount: 1, unreadMark: false }])
  })
})
