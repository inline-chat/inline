import { expect, test } from "bun:test"
import { and, asc, eq } from "drizzle-orm"
import { drizzle } from "drizzle-orm/postgres-js"
import postgres from "postgres"
import { db } from "@in/server/db"
import { installPostCommitHooks, waitForPostCommitHooks } from "@in/server/db/commitHooks"
import * as schema from "@in/server/db/schema"
import { relations } from "@in/server/db/relations"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { setupTestLifecycle, testUtils } from "../setup"

setupTestLifecycle()
const input = (userId: number, marker: number) => ({
  userId,
  update: {
    oneofKind: "userReadMaxId" as const,
    userReadMaxId: { peerId: { type: { oneofKind: "chat" as const, chat: { chatId: 123n } } }, readMaxId: BigInt(marker), unreadCount: 0 },
  },
})
const journal = (userId: number) => db.select().from(schema.updates)
  .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, userId))).orderBy(asc(schema.updates.seq))

test("batching preserves duplicate-owner order, caller result order, encryption and stale-counter recovery", async () => {
  const a = await testUtils.createUser("batch-a@example.test")
  const b = await testUtils.createUser("batch-b@example.test")
  await UserBucketUpdates.enqueue(input(a.id, 1))
  await db.update(schema.users).set({ updateSeq: 0 }).where(eq(schema.users.id, a.id))
  const result = await UserBucketUpdates.enqueueMany([input(b.id, 10), input(a.id, 20), input(b.id, 30), input(a.id, 40)])
  expect(result.map((entry) => entry.seq)).toEqual([1, 2, 2, 3])
  const first = await journal(a.id), second = await journal(b.id)
  const markers = (rows: typeof first) => rows.map((row) => {
    const update = UpdatesModel.decrypt(row).payload.update
    if (update.oneofKind !== "userReadMaxId") throw new Error("Incorrect replay payload")
    return update.userReadMaxId.readMaxId
  })
  expect(markers(first)).toEqual([1n, 20n, 40n])
  expect(markers(second)).toEqual([10n, 30n])
  expect(result.map((entry) => entry.date.getTime())).toEqual([second[0]!, first[1]!, second[1]!, first[2]!].map((row) => row.date.getTime()))
  for (const rows of [first, second]) {
    expect(rows.every((row) => row.payload instanceof Buffer && row.payload.length > 0)).toBe(true)
    expect(rows.map((row) => row.date.getTime())).toEqual(rows.map((row) => row.date.getTime()).sort((a, b) => a - b))
  }
})

test("independent database clients can allocate overlapping owner batches without lost updates or deadlock", async () => {
  const a = await testUtils.createUser("concurrent-a@example.test")
  const b = await testUtils.createUser("concurrent-b@example.test")
  // Separate pools model separate server DB connections. This proves DB-level
  // coordination only, not cross-server caches, WebSocket delivery or leadership.
  const clients = [postgres(process.env["DATABASE_URL"]!, { max: 1 }), postgres(process.env["DATABASE_URL"]!, { max: 1 })]
  const databases = clients.map((client) => installPostCommitHooks(drizzle(client, { schema, relations })))
  const ready = Promise.withResolvers<void>()
  let arrivals = 0
  try {
    const results = await Promise.allSettled(databases.map((database, index) => database.transaction(async (tx) => {
      if (++arrivals === 2) ready.resolve()
      await ready.promise
      const batch = index === 0 ? [input(a.id, 1), input(b.id, 2)] : [input(b.id, 3), input(a.id, 4)]
      return UserBucketUpdates.enqueueMany(batch, { tx })
    }).catch((error) => { ready.resolve(); throw error })))
    expect(results.map((result) => result.status)).toEqual(["fulfilled", "fulfilled"])
    for (const user of [a, b]) {
      const rows = await journal(user.id)
      expect(rows.map((row) => row.seq)).toEqual([1, 2])
      const [owner] = await db.select().from(schema.users).where(eq(schema.users.id, user.id))
      expect(owner?.updateSeq).toBe(2)
    }
  } finally {
    await waitForPostCommitHooks()
    await Promise.all(clients.map((client) => client.end({ timeout: 5 })))
  }
})

test("a later batch failure rolls back earlier owner counters and encrypted journal rows", async () => {
  const user = await testUtils.createUser("batch-rollback@example.test")
  const before = await db.select().from(schema.users).where(eq(schema.users.id, user.id))
  await expect(UserBucketUpdates.enqueueMany([input(user.id, 1), input(2_147_483_647, 2)])).rejects.toThrow("Failed to allocate")
  expect(await journal(user.id)).toEqual([])
  expect(await db.select().from(schema.users).where(eq(schema.users.id, user.id))).toEqual(before)
  expect((await UserBucketUpdates.enqueue(input(user.id, 3))).seq).toBe(1)
})
