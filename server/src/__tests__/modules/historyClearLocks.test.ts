import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { chatParticipants, chats, members, messages, spaces, updates, users, UpdateBucket } from "@in/server/db/schema"
import { clearChatHistory } from "@in/server/modules/historyClear"
import * as historyData from "@in/server/modules/historyClear/data"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((ready) => { resolve = ready })
  return { promise, resolve }
}

const fixture = async (label: string) => {
  const owner = await testUtils.createUser(`${label}-owner@example.com`)
  const recipient = await testUtils.createUser(`${label}-recipient@example.com`)
  const space = await testUtils.createSpace(label)
  if (!space) throw new Error("Fixture space missing")
  await db.insert(members).values([
    { userId: owner.id, spaceId: space.id, role: "owner" },
    { userId: recipient.id, spaceId: space.id, role: "member" },
  ])
  const root = await testUtils.createChat(space.id, "Root", "thread", true, owner.id)
  if (!root) throw new Error("Fixture root missing")
  await db.insert(messages).values({ chatId: root.id, messageId: 1, fromId: owner.id })
  const [child] = await db.insert(chats).values({
    type: "thread", spaceId: space.id, parentChatId: root.id, parentMessageId: 1, publicThread: false,
  }).returning()
  if (!child) throw new Error("Fixture child missing")
  return { owner, recipient, space, root, child }
}

describe("history clear mutation owners", () => {
  setupTestLifecycle()

  test("peer clear yields before owning the root when a user-first writer needs it", async () => {
    const owner = await testUtils.createUser("clear-peer-lock-owner@example.com")
    const root = await testUtils.createChat(null, "Home root", "thread", false, owner.id)
    if (!root) throw new Error("Fixture root missing")
    await db.insert(chatParticipants).values({ chatId: root.id, userId: owner.id })
    await db.insert(messages).values({ chatId: root.id, messageId: 1, fromId: owner.id })
    const [child] = await db.insert(chats).values({
      type: "thread",
      spaceId: null,
      parentChatId: root.id,
      parentMessageId: 1,
      publicThread: false,
      createdBy: owner.id,
    }).returning()
    if (!child) throw new Error("Fixture child missing")

    const userLocked = deferred()
    const requestRoot = deferred()
    const writer = db.transaction(async (tx) => {
      await tx.select().from(users).where(eq(users.id, owner.id)).for("update")
      userLocked.resolve()
      await requestRoot.promise
      await tx.execute(sql`select set_config('lock_timeout', '500ms', true)`)
      await tx.select().from(chats).where(eq(chats.id, root.id)).for("update")
    })
    await userLocked.promise

    const plan = historyData.planClearChatHistoryData
    let calls = 0
    const planning = spyOn(historyData, "planClearChatHistoryData").mockImplementation(async (tx, input) => {
      if (++calls === 2) {
        // The failed NOWAIT user prelock rolled back before this fresh plan.
        // A user-first reply writer can now acquire its parent Chat and finish.
        requestRoot.resolve()
        await writer
      }
      return await plan(tx, input)
    })

    try {
      await clearChatHistory(
        {
          peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(root.id) } } },
          keepLastDays: 0,
          deleteReplyThreads: true,
        },
        { currentUserId: owner.id },
      )
      expect(calls).toBe(3)
      expect(await db.select().from(chats).where(eq(chats.id, child.id))).toHaveLength(0)
      expect(await db.select().from(messages).where(eq(messages.chatId, root.id))).toHaveLength(0)
    } finally {
      requestRoot.resolve()
      await Promise.allSettled([writer])
      planning.mockRestore()
    }
  })

  for (const change of ["demoted actor", "deleted space", "deleted actor"] as const) {
    test(`revalidates ${change} after optimistic admission`, async () => {
      const { owner, space, root } = await fixture(`clear-lock-${change.replaceAll(" ", "-")}`)
      const plan = historyData.planClearSpaceHistoryData
      let calls = 0
      const planning = spyOn(historyData, "planClearSpaceHistoryData").mockImplementation(async (tx, input) => {
        const result = await plan(tx, input)
        if (++calls === 1) {
          if (change === "demoted actor") {
            await db.update(members).set({ role: "member" }).where(and(eq(members.spaceId, space.id), eq(members.userId, owner.id)))
          } else if (change === "deleted space") {
            await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, space.id))
          } else {
            await db.update(users).set({ deleted: true }).where(eq(users.id, owner.id))
          }
        }
        return result
      })
      try {
        await expect(clearChatHistory({ spaceId: space.id, keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: owner.id }))
          .rejects.toMatchObject({ code: change === "demoted actor"
            ? RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED
            : change === "deleted space" ? RealtimeRpcError.Code.SPACE_ID_INVALID : RealtimeRpcError.Code.UNAUTHENTICATED })
        expect(await db.select().from(messages).where(eq(messages.chatId, root.id))).toHaveLength(1)
        expect(await db.select().from(updates)).toHaveLength(0)
      } finally {
        planning.mockRestore()
      }
    })
  }

  test("prelocks affected users before space so a membership writer can finish", async () => {
    const { owner, recipient, space } = await fixture("clear-lock-membership-order")
    const rowLocked = deferred()
    const requestSpace = deferred()
    let writerPid = 0
    const writer = db.transaction(async (tx) => {
      const [backend] = await tx.execute<{ pid: number }>(sql`select pg_backend_pid() as pid`)
      writerPid = backend!.pid
      await tx.select().from(users).where(eq(users.id, recipient.id)).for("update")
      rowLocked.resolve()
      await requestSpace.promise
      await tx.execute(sql`select set_config('lock_timeout', '500ms', true)`)
      await tx.select().from(spaces).where(eq(spaces.id, space.id)).for("update")
    })
    await rowLocked.promise
    const clearing = clearChatHistory({ spaceId: space.id, keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: owner.id })
    try {
      const deadline = performance.now() + 2_000
      let blocked = false
      while (performance.now() < deadline) {
        const [row] = await db.execute<{ blocked: boolean }>(sql`
          select exists(select 1 from pg_stat_activity where ${writerPid} = any(pg_blocking_pids(pid))) as blocked
        `)
        if (row?.blocked) { blocked = true; break }
        await Bun.sleep(10)
      }
      expect(blocked).toBe(true)
      requestSpace.resolve()
      await Promise.all([writer, clearing])
    } finally {
      requestSpace.resolve()
      await Promise.allSettled([writer, clearing])
    }
  })

  test("a late external-root recipient rolls back and is prelocked on the next plan", async () => {
    const { owner, space, root, child } = await fixture("clear-lock-late-recipient")
    const external = await testUtils.createChat(null, "External ancestor", "thread", false, owner.id)
    const lateUser = await testUtils.createUser("clear-lock-late-user@example.com")
    if (!external) throw new Error("Fixture ancestor missing")
    await db.insert(members).values({ spaceId: space.id, userId: lateUser.id, role: "member" })
    await db.insert(messages).values({ chatId: external.id, messageId: 1, fromId: owner.id })
    await db.insert(chatParticipants).values({ chatId: external.id, userId: owner.id })
    await db.update(chats).set({ parentChatId: external.id, parentMessageId: 1, publicThread: false }).where(eq(chats.id, root.id))
    const plan = historyData.planClearSpaceHistoryData
    let calls = 0
    const planning = spyOn(historyData, "planClearSpaceHistoryData").mockImplementation(async (tx, input) => {
      const result = await plan(tx, input)
      if (++calls === 2) {
        // The plan was read under the mutation's locks, but this independent
        // ancestor isn't a mutation owner and may gain a recipient meanwhile.
        await db.insert(chatParticipants).values({ chatId: external.id, userId: lateUser.id })
      }
      return result
    })
    try {
      await clearChatHistory({ spaceId: space.id, keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: owner.id })
      expect(calls).toBe(4)
      const lateUpdates = await db.select().from(updates).where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, lateUser.id)))
      expect(lateUpdates.map((row) => row.seq)).toEqual([1])
      expect(await db.select().from(chats).where(eq(chats.id, child.id))).toHaveLength(0)
    } finally {
      planning.mockRestore()
    }
  })

  test("yields its user locks when a chat-first writer needs to finish", async () => {
    const { owner, recipient, space, root } = await fixture("clear-lock-chat-first")
    const rowLocked = deferred()
    const requestUser = deferred()
    const retried = deferred()
    const writer = db.transaction(async (tx) => {
      await tx.select().from(chats).where(eq(chats.id, root.id)).for("update")
      rowLocked.resolve()
      await requestUser.promise
      await tx.execute(sql`select set_config('lock_timeout', '500ms', true)`)
      await tx.select().from(users).where(eq(users.id, recipient.id)).for("update")
    })
    await rowLocked.promise
    const plan = historyData.planClearSpaceHistoryData
    let calls = 0
    const planning = spyOn(historyData, "planClearSpaceHistoryData").mockImplementation(async (tx, input) => {
      if (++calls === 2) {
        // The NOWAIT failure has rolled back before this fresh plan starts.
        retried.resolve()
        requestUser.resolve()
        await writer
      }
      return await plan(tx, input)
    })
    const clearing = clearChatHistory({ spaceId: space.id, keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: owner.id })
    try {
      expect(await Promise.race([retried.promise.then(() => true), Bun.sleep(1_000).then(() => false)])).toBe(true)
      await Promise.all([writer, clearing])
      expect(calls).toBe(3)
    } finally {
      requestUser.resolve()
      await Promise.allSettled([writer, clearing])
      planning.mockRestore()
    }
  })

  test("bounded resource contention fails without mutating messages or journals", async () => {
    const { owner, space, root, child } = await fixture("clear-lock-busy-bound")
    const rowLocked = deferred()
    const release = deferred()
    const writer = db.transaction(async (tx) => {
      await tx.select().from(spaces).where(eq(spaces.id, space.id)).for("update")
      rowLocked.resolve()
      await release.promise
    })
    await rowLocked.promise
    try {
      await expect(clearChatHistory({ spaceId: space.id, keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: owner.id }))
        .rejects.toMatchObject({ code: RealtimeRpcError.Code.INTERNAL_ERROR })
      expect(await db.select().from(messages).where(eq(messages.chatId, root.id))).toHaveLength(1)
      expect(await db.select().from(chats).where(eq(chats.id, child.id))).toHaveLength(1)
      expect(await db.select().from(updates)).toHaveLength(0)
    } finally {
      release.resolve()
      await writer
    }
  })

  test("three unstable plans fail without deleting messages or publishing updates", async () => {
    const { owner, space, root, child } = await fixture("clear-lock-retry-bound")
    const lateUser = await testUtils.createUser("clear-lock-unstable@example.com")
    const plan = historyData.planClearSpaceHistoryData
    let calls = 0
    const planning = spyOn(historyData, "planClearSpaceHistoryData").mockImplementation(async (tx, input) => {
      const result = await plan(tx, input)
      return ++calls % 2 === 0
        ? { ...result, recipientUserIds: [...result.recipientUserIds, lateUser.id].sort((a, b) => a - b) }
        : result
    })
    try {
      await expect(clearChatHistory({ spaceId: space.id, keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: owner.id }))
        .rejects.toMatchObject({ code: RealtimeRpcError.Code.INTERNAL_ERROR })
      expect(calls).toBe(6)
      expect(await db.select().from(messages).where(eq(messages.chatId, root.id))).toHaveLength(1)
      expect(await db.select().from(chats).where(eq(chats.id, child.id))).toHaveLength(1)
      expect(await db.select().from(updates)).toHaveLength(0)
    } finally {
      planning.mockRestore()
    }
  })
})
