import { afterAll, beforeAll, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { UpdateBucket, chats, dialogs, members, spaces, updates, users } from "@in/server/db/schema"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { captureUpdateDiscoveryWatermark } from "@in/server/modules/updates/updateDiscoveryBarrier"
import { loadRepairUserFrontiers, postgresRepairDiscovery } from "@in/server/modules/internalMessaging/repairDiscovery.postgres"
import { setupTestDatabase, teardownTestDatabase } from "../database"
import { distribution, measureOperation } from "./measure"
import { ConnectedUserRepair } from "@in/server/modules/internalMessaging/repair"

// This measures real dated discovery, not the no-date bootstrap fast path.
// It has no sockets/providers and therefore claims DB sweep cost only.
let userIds: number[] = []
let chatId = 0
let spaceId = 0
beforeAll(async () => {
  await setupTestDatabase()
  const actors = await db.insert(users).values(Array.from({ length: 1000 }, (_, i) => ({
    email: `repair-cost-${i}@example.test`,
  }))).returning({ id: users.id })
  userIds = actors.map((user) => user.id)
  const [space] = await db.insert(spaces).values({ name: "Discovery cost fixture" }).returning()
  if (!space) throw new Error("Missing fixture space")
  spaceId = space.id
  await db.insert(members).values(userIds.map((userId) => ({
    userId, spaceId: space.id, role: "member" as const, canAccessPublicChats: true,
  })))
  const buckets = await db.insert(chats).values(Array.from({ length: 5 }, () => ({
    type: "thread" as const, spaceId: space.id, publicThread: true,
    title: "Named fixture thread", isUntitled: false,
    lastUpdateDate: new Date(0),
  }))).returning({ id: chats.id })
  chatId = buckets[0]!.id
  for (const bucket of buckets) {
    await db.insert(dialogs).values(userIds.map((userId) => ({
      userId, chatId: bucket.id, spaceId: space.id, open: true, order: "a0",
    })))
  }
}, 30_000)
afterAll(teardownTestDatabase)

for (const size of [1, 10, 100, 1000]) {
  for (const dirty of [false, true]) {
    test(`dated repair discovery: ${size} users, ${dirty ? "changed shared chat" : "idle"}`, async () => {
      const before = await captureUpdateDiscoveryWatermark()
      const checkpoint = BigInt(Math.floor(before.getTime() / 1000) - 1)
      await db.update(chats).set({ lastUpdateDate: dirty ? before : new Date(0) }).where(eq(chats.id, chatId))
      const selected = userIds.slice(0, size)
      const measure = (mode: "individual" | "shared" | "batched" | "prefiltered") => measureOperation(db.$client.options, async () => {
        const discoveryWatermark = mode === "individual" ? undefined : await captureUpdateDiscoveryWatermark()
        const frontiers = mode === "batched" ? await loadRepairUserFrontiers(selected) : undefined
        const snapshots = mode === "prefiltered"
          ? await postgresRepairDiscovery.prepare(selected.map((userId) => ({ userId, date: checkpoint })), discoveryWatermark!)
          : undefined
        // Match the repair service's eight active account scans, in one worker.
        let next = 0
        await Promise.all(Array.from({ length: Math.min(8, size) }, async () => {
          while (next < selected.length) {
            const userId = selected[next++]!
            const result = mode === "prefiltered"
              ? await postgresRepairDiscovery.discover({ userId, date: checkpoint }, {
                snapshot: snapshots?.get(userId), shouldEmitHints: () => true,
              })
              : await getUpdatesState({ date: checkpoint }, {
              currentUserId: userId, currentSessionId: 0,
            }, { discoveryWatermark, userFrontier: frontiers?.get(userId) })
            expect(result.date).toBeGreaterThanOrEqual(checkpoint)
            expect(result.updatesFound).toBe(dirty)
          }
        }))
      }, async () => {})
      const individual = await measure("individual")
      const shared = await measure("shared")
      const batched = await measure("batched")
      const prefiltered = await measure("prefiltered")
      // Count all driver commands, including BEGIN/COMMIT and fence SQL.
      // Individual exclusive fences also contend with each other: failed
      // lock attempts add BEGIN/try/COMMIT retries, so their cost is a floor.
      expect(individual.sql.commands - shared.sql.commands).toBeGreaterThanOrEqual(4 * (size - 1))
      expect(shared.sql.commands).toBe(4 + (dirty ? 7 : 5) * size)
      expect(batched.sql.commands).toBe(4 + (dirty ? 5 : 3) * size + Math.ceil(size / 512))
      // Regression gate: idle cost scales with bounded batches, not accounts.
      // Changed accounts retain the authoritative path; prefilter overhead is
      // at most one extra statement per batch compared with the old strategy.
      expect(prefiltered.sql.commands).toBe(4 + (dirty ? 5 : 0) * size + 2 * Math.ceil(size / 512))
      expect(prefiltered.settledMs).toBeLessThan(10_000)
      console.info(JSON.stringify({
        case: "dated-discovery-cost", users: size, dirty,
        individual: { commands: individual.sql.commands, sweepMs: individual.settledMs },
        shared: { commands: shared.sql.commands, sweepMs: shared.settledMs },
        batched: { commands: batched.sql.commands, sweepMs: batched.settledMs },
        prefiltered: { commands: prefiltered.sql.commands, sweepMs: prefiltered.settledMs },
      }))
    }, 30_000)
  }
}

test("the real scheduler uses batched discovery for one thousand idle users", async () => {
  await db.update(chats).set({ lastUpdateDate: new Date(0) })
  const repair = new ConnectedUserRepair({
    discovery: postgresRepairDiscovery,
    connectedUserIds: () => userIds,
    hasConnections: () => true,
    getConnectionEpoch: () => 1,
    emitUserHint: async () => 1,
    replayCurrentUserUpdate: async () => "replayed",
    closeForUnrecoverableFrontier: () => { throw new Error("Idle repair must not disconnect users") },
    deliverTargetedBucketHint: async () => {},
  })
  try {
    await repair.start()
    const sample = await measureOperation(db.$client.options, async () => {
      repair.observeConnectedUsers()
    }, () => repair.waitForIdle())
    expect(sample.sql.commands).toBe(8)
  } finally { await repair.stop() }
})

test("sparse activity only pays full discovery for the ten affected accounts", async () => {
  await db.update(chats).set({ lastUpdateDate: new Date(0) })
  const [other] = await db.insert(users).values({ email: "repair-cost-outsider@example.test" }).returning()
  const before = await captureUpdateDiscoveryWatermark()
  const date = BigInt(Math.floor(before.getTime() / 1000) - 1)
  await db.insert(chats).values(userIds.slice(0, 10).map((userId) => ({
    type: "private" as const, minUserId: userId, maxUserId: other!.id, lastUpdateDate: before,
  })))
  const samples = []
  for (const optimized of [false, true]) {
    samples.push(await measureOperation(db.$client.options, async () => {
      const watermark = await captureUpdateDiscoveryWatermark()
      const snapshots = optimized
        ? await postgresRepairDiscovery.prepare(userIds.map((userId) => ({ userId, date })), watermark)
        : undefined
      const frontiers = optimized ? undefined : await loadRepairUserFrontiers(userIds)
      let next = 0
      await Promise.all(Array.from({ length: 8 }, async () => {
        while (next < userIds.length) {
          const index = next++
          const userId = userIds[index]!
          const result = optimized
            ? await postgresRepairDiscovery.discover({ userId, date }, { snapshot: snapshots?.get(userId), shouldEmitHints: () => true })
            : await getUpdatesState({ date }, { currentUserId: userId, currentSessionId: 0 }, {
              discoveryWatermark: watermark, userFrontier: frontiers?.get(userId),
            })
          expect(result.updatesFound).toBe(index < 10)
        }
      }))
    }, async () => {}))
  }
  expect(samples[0]!.sql.commands).toBe(3016)
  expect(samples[1]!.sql.commands).toBe(48)
  expect(samples[1]!.settledMs).toBeLessThan(10_000)
  console.info(JSON.stringify({ case: "sparse-discovery-cost", users: 1000, affected: 10,
    before: { commands: samples[0]!.sql.commands, sweepMs: samples[0]!.settledMs },
    after: { commands: samples[1]!.sql.commands, sweepMs: samples[1]!.settledMs },
  }))
}, 30_000)

test("batched frontiers reconcile cached counters/history and observe later commits on the next sweep", async () => {
  const userId = userIds[0]!
  await db.update(users).set({ updateSeq: 3 }).where(eq(users.id, userId))
  // Only sequence metadata is read in this fixture; no payload is replayed.
  await db.insert(updates).values({ bucket: UpdateBucket.User, entityId: userId, seq: 17, payload: Buffer.alloc(0) })
  const first = await loadRepairUserFrontiers([userId, userId, userIds[1]!])
  expect(first.get(userId)).toBe(17)
  expect(first.get(userIds[1]!)).toBe(0)

  await db.update(users).set({ updateSeq: 30 }).where(eq(users.id, userId))
  const next = await loadRepairUserFrontiers([userId])
  expect(first.get(userId)).toBe(17)
  expect(next.get(userId)).toBe(30)
  const authoritative = await getUpdatesState({}, { currentUserId: userId, currentSessionId: 0 })
  expect(authoritative.seq).toBe(next.get(userId))
})

test("wide idle memberships keep bounded results and batch cost", async () => {
  await db.update(chats).set({ lastUpdateDate: new Date(0) })
  await db.insert(chats).values(Array.from({ length: 1000 }, () => ({
    type: "thread" as const, spaceId, publicThread: true, lastUpdateDate: new Date(0),
  })))
  const watermark = await captureUpdateDiscoveryWatermark()
  const date = BigInt(Math.floor(watermark.getTime() / 1000) - 1)
  const requests = userIds.map((userId) => ({ userId, date }))
  const elapsed = []
  for (let repetition = 0; repetition < 5; repetition++) {
    const sample = await measureOperation(db.$client.options, async () => {
      const snapshots = await postgresRepairDiscovery.prepare(requests, watermark)
      expect(snapshots.size).toBe(1000)
      for (const snapshot of snapshots.values()) expect(snapshot.resourcesUnchangedSince).toBe(date)
    }, async () => {})
    // Preparation only: the fence was measured separately by the other cases.
    expect(sample.sql.commands).toBe(4)
    expect(sample.settledMs).toBeLessThan(10_000)
    elapsed.push(sample.settledMs)
  }
  console.info(JSON.stringify({ case: "wide-idle-discovery", users: 1000, sharedChats: 1005,
    commands: 4, preparationMs: distribution(elapsed),
  }))
  await db.update(chats).set({ lastUpdateDate: watermark }).where(eq(chats.spaceId, spaceId))
  const busy = await measureOperation(db.$client.options, async () => {
    const snapshots = await postgresRepairDiscovery.prepare(requests, watermark)
    expect(snapshots.size).toBe(1000)
    for (const snapshot of snapshots.values()) expect(snapshot.resourcesUnchangedSince).toBeUndefined()
  }, async () => {})
  expect(busy.sql.commands).toBe(4)
  expect(busy.settledMs).toBeLessThan(10_000)
  console.info(JSON.stringify({ case: "wide-busy-discovery", users: 1000, sharedChats: 1005,
    commands: busy.sql.commands, preparationMs: busy.settledMs,
  }))
}, 30_000)
