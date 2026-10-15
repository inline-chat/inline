import { expect, test } from "bun:test"
import { asc, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogs, users } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "../__tests__/setup"
import { measureOperation } from "../__tests__/performance/measure"
import { setDialogOpenForUsers } from "./dialogOpen"

setupTestLifecycle()

test("one hundred unchanged dialogs use a constant query budget and preserve their state", async () => {
  const actors = await db.insert(users).values(Array.from({ length: 100 }, (_, i) => ({ email: `batch-${i}@example.test` }))).returning()
  const chat = await testUtils.createChat(null)
  if (!chat) throw new Error("Missing chat")
  await db.insert(dialogs).values(actors.map((user) => ({
    userId: user.id, chatId: chat.id, open: true, order: "a0", archived: false,
  })))
  const before = await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id)).orderBy(asc(dialogs.userId))
  const sample = await measureOperation(db.$client.options, async () => {
    const result = await setDialogOpenForUsers({ chat, userIds: actors.map((user) => user.id), open: true })
    expect(result.changedDialogs).toEqual([])
    expect(result.dialogs.toSorted((a, b) => a.userId - b.userId)).toEqual(before)
  }, async () => {})
  // Active owners, BEGIN, one sorted owner-lock batch, existing dialogs, COMMIT.
  expect(sample.sql.commands).toBe(5)
  expect(await db.select().from(dialogs).where(eq(dialogs.chatId, chat.id)).orderBy(asc(dialogs.userId))).toEqual(before)
})

test("overlapping reversed owner batches keep independent chat allocations ordered without deadlock", async () => {
  const actors = await db.insert(users).values(Array.from({ length: 10 }, (_, i) => ({ email: `overlap-${i}@example.test` }))).returning()
  const first = await testUtils.createChat(null)
  const second = await testUtils.createChat(null)
  if (!first || !second) throw new Error("Missing chats")
  const ids = actors.map((user) => user.id)
  const results = await Promise.allSettled([
    setDialogOpenForUsers({ chat: first, userIds: [...ids, ids[0]!], open: true }),
    setDialogOpenForUsers({ chat: second, userIds: ids.toReversed(), open: true }),
  ])
  for (const result of results) {
    if (result.status === "rejected") throw result.reason
    expect(result.value.dialogs).toHaveLength(10)
    expect(result.value.changedDialogs).toHaveLength(10)
  }
  for (const user of actors) {
    const rows = await db.select().from(dialogs).where(eq(dialogs.userId, user.id))
    expect(rows).toHaveLength(2)
    expect(rows.every((row) => row.open === true && row.order !== null)).toBe(true)
    expect(new Set(rows.map((row) => row.order)).size).toBe(2)
  }
})

test("closing metadata-only state returns persisted cleared fields even without a visibility change", async () => {
  const actor = await testUtils.createUser()
  const chat = await testUtils.createChat(null)
  if (!chat) throw new Error("Missing chat")
  await db.insert(dialogs).values({ userId: actor.id, chatId: chat.id, open: false, order: "a0" })
  const result = await setDialogOpenForUsers({ chat, userIds: [actor.id], open: false })
  expect(result.changedDialogs).toEqual([])
  expect(result.dialogs[0]?.order).toBeNull()
  const repeated = await setDialogOpenForUsers({ chat, userIds: [actor.id], open: false })
  expect(repeated.dialogs).toEqual(result.dialogs)
})
