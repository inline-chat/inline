import { afterEach, expect, test } from "bun:test"
import { eq, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { RecentRealtimeBuckets, MAX_RECENT_REALTIME_BUCKET_PAGE_SIZE } from "@in/server/db/models/recentRealtimeBuckets"
import { UpdatesModel } from "@in/server/db/models/updates"
import { recentRealtimeBuckets, updates, UpdateBucket } from "@in/server/db/schema"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { setupTestLifecycle, testUtils } from "../setup"

setupTestLifecycle()

const originalMode = process.env["REALTIME_DISTRIBUTED"]
afterEach(async () => {
  await waitForPostCommitHooks()
  if (originalMode === undefined) delete process.env["REALTIME_DISTRIBUTED"]
  else process.env["REALTIME_DISTRIBUTED"] = originalMode
})

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((ready) => { resolve = ready })
  return { promise, resolve }
}

const record = (entityId: number, seq: number, bucket: UpdateBucket = UpdateBucket.Chat) =>
  db.transaction((tx) => RecentRealtimeBuckets.record(tx, { bucket, entityId, seq }))

test("distributed journal commits register chat, space and user frontiers atomically", async () => {
  process.env["REALTIME_DISTRIBUTED"] = "1"
  const user = await testUtils.createUser("recent-realtime@example.test")
  await db.transaction(async (tx) => {
    await UpdatesModel.insertUpdate(tx, {
      bucket: UpdateBucket.Chat, entity: { id: 501, updateSeq: 3 },
      update: { oneofKind: "deleteMessages", deleteMessages: { chatId: 501n, msgIds: [1n] } },
    })
    await UpdatesModel.insertUpdate(tx, {
      bucket: UpdateBucket.Space, entity: { id: 502, updateSeq: 7 },
      update: { oneofKind: "spaceClearHistory", spaceClearHistory: {
        spaceId: 502n, deleteReplyThreads: false,
        deletedChatIds: [], orphanedChatIds: [], detachedChatIds: [],
      } },
    })
    await UserBucketUpdates.enqueue({ userId: user.id, update: {
      oneofKind: "userDialogArchived",
      userDialogArchived: { peerId: { type: { oneofKind: "chat", chat: { chatId: 501n } } }, archived: true },
    } }, { tx })
  })
  const rows = await RecentRealtimeBuckets.readPage()
  expect(rows.map(({ bucket, entityId, seq }) => ({ bucket, entityId, seq }))).toEqual([
    { bucket: UpdateBucket.Chat, entityId: 501, seq: 4 },
    { bucket: UpdateBucket.User, entityId: user.id, seq: 1 },
    { bucket: UpdateBucket.Space, entityId: 502, seq: 8 },
  ])
  const [clock] = await db.execute<{ withinTtl: boolean }>(sql`
    select bool_and(expires_at > clock_timestamp() and expires_at <= clock_timestamp() + interval '5 minutes') as "withinTtl"
    from ${recentRealtimeBuckets}
  `)
  expect(clock?.withinTtl).toBe(true)
})

test("rollback removes both the journal write and its discovery metadata", async () => {
  process.env["REALTIME_DISTRIBUTED"] = "1"
  await expect(db.transaction(async (tx) => {
    await UpdatesModel.insertUpdate(tx, {
      bucket: UpdateBucket.Chat, entity: { id: 501, updateSeq: 0 },
      update: { oneofKind: "deleteMessages", deleteMessages: { chatId: 501n, msgIds: [1n] } },
    })
    throw new Error("abort fixture")
  })).rejects.toThrow("abort fixture")
  expect(await db.select().from(updates)).toEqual([])
  expect(await RecentRealtimeBuckets.readPage()).toEqual([])
})

test("explicit single-server mode adds no discovery rows for either journal writer", async () => {
  process.env["REALTIME_DISTRIBUTED"] = "0"
  const user = await testUtils.createUser("local-realtime@example.test")
  await db.transaction(async (tx) => {
    await UpdatesModel.insertUpdate(tx, {
      bucket: UpdateBucket.Chat, entity: { id: 501, updateSeq: 0 },
      update: { oneofKind: "deleteMessages", deleteMessages: { chatId: 501n, msgIds: [1n] } },
    })
    await UserBucketUpdates.enqueue({ userId: user.id, update: {
      oneofKind: "userDialogArchived",
      userDialogArchived: { peerId: { type: { oneofKind: "chat", chat: { chatId: 501n } } }, archived: true },
    } }, { tx })
  })
  expect(await db.select().from(updates)).toHaveLength(2)
  expect(await db.select().from(recentRealtimeBuckets)).toEqual([])
})

test("overlapping writers preserve the highest committed sequence", async () => {
  const firstRecorded = deferred()
  const releaseFirst = deferred()
  const first = db.transaction(async (tx) => {
    await RecentRealtimeBuckets.record(tx, { bucket: UpdateBucket.Chat, entityId: 501, seq: 7 })
    firstRecorded.resolve()
    await releaseFirst.promise
  })
  await firstRecorded.promise
  const second = record(501, 8)
  const stale = record(501, 6)
  releaseFirst.resolve()
  const results = await Promise.allSettled([first, second, stale])
  expect(results.every((result) => result.status === "fulfilled")).toBe(true)
  const rows = await RecentRealtimeBuckets.readPage()
  expect(rows).toHaveLength(1)
  expect(rows[0]?.seq).toBe(8)
})

test("only new committed sequences renew TTL; expired metadata never appears in reads", async () => {
  await record(501, 7)
  await db.update(recentRealtimeBuckets).set({ expiresAt: sql`clock_timestamp() - interval '1 second'` })
  const [expired] = await db.select().from(recentRealtimeBuckets)
  await record(501, 7)
  await record(501, 6)
  expect(await RecentRealtimeBuckets.readPage()).toEqual([])
  const [unchanged] = await db.select().from(recentRealtimeBuckets)
  expect(unchanged?.expiresAt).toEqual(expired?.expiresAt)
  await record(501, 8)
  expect((await RecentRealtimeBuckets.readPage())[0]?.seq).toBe(8)
  expect(await RecentRealtimeBuckets.cleanupExpired()).toBe(0)
})

test("keyset pages are bounded and a fresh cycle sees commits behind its previous cursor", async () => {
  await db.insert(recentRealtimeBuckets).values(Array.from({ length: 260 }, (_, offset) => ({
    bucket: UpdateBucket.Chat, entityId: offset + 10, seq: 1,
    expiresAt: sql`clock_timestamp() + interval '5 minutes'`,
  })))
  const first = await RecentRealtimeBuckets.readPage()
  expect(first).toHaveLength(MAX_RECENT_REALTIME_BUCKET_PAGE_SIZE)
  const last = first.at(-1)
  if (!last) throw new Error("Missing page frontier")
  await record(1, 1)
  const next = await RecentRealtimeBuckets.readPage({ after: last })
  expect(next.map((row) => row.entityId)).toEqual([266, 267, 268, 269])
  expect((await RecentRealtimeBuckets.readPage({ limit: 1 }))[0]?.entityId).toBe(1)
  await expect(RecentRealtimeBuckets.readPage({ limit: 257 })).rejects.toThrow("page size")
  await expect(RecentRealtimeBuckets.cleanupExpired(257)).rejects.toThrow("page size")
})

test("cleanup is bounded and skips a bucket held by a concurrent writer", async () => {
  await db.insert(recentRealtimeBuckets).values([1, 2, 3].map((entityId) => ({
    bucket: UpdateBucket.Chat, entityId, seq: 1,
    expiresAt: sql`clock_timestamp() - interval '1 second'`,
  })))
  const locked = deferred()
  const release = deferred()
  const writer = db.transaction(async (tx) => {
    await tx.select().from(recentRealtimeBuckets).where(eq(recentRealtimeBuckets.entityId, 1)).for("update")
    locked.resolve()
    await release.promise
    await RecentRealtimeBuckets.record(tx, { bucket: UpdateBucket.Chat, entityId: 1, seq: 2 })
  })
  await locked.promise
  try {
    expect(await RecentRealtimeBuckets.cleanupExpired(1)).toBe(1)
    expect(await db.select().from(recentRealtimeBuckets)).toHaveLength(2)
    expect(await RecentRealtimeBuckets.cleanupExpired(1)).toBe(1)
    expect(await RecentRealtimeBuckets.cleanupExpired(1)).toBe(0)
  } finally {
    release.resolve()
    await writer
  }
  expect((await RecentRealtimeBuckets.readPage()).map(({ entityId, seq }) => ({ entityId, seq })))
    .toEqual([{ entityId: 1, seq: 2 }])
})
