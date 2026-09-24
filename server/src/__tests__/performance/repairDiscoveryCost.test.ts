import { afterAll, beforeAll, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { UpdateBucket, chats, dialogs, members, spaces, updates, users } from "@in/server/db/schema"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { captureUpdateDiscoveryWatermark } from "@in/server/modules/updates/updateDiscoveryBarrier"
import { loadRepairUserFrontiers } from "@in/server/modules/internalMessaging/repairDiscovery"
import { setupTestDatabase, teardownTestDatabase } from "../database"
import { measureOperation } from "./measure"

// This measures real dated discovery, not the no-date bootstrap fast path.
// It has no sockets/providers and therefore claims DB sweep cost only.
let userIds: number[] = []
let chatId = 0
beforeAll(async () => {
  await setupTestDatabase()
  const actors = await db.insert(users).values(Array.from({ length: 1000 }, (_, i) => ({
    email: `repair-cost-${i}@example.test`,
  }))).returning({ id: users.id })
  userIds = actors.map((user) => user.id)
  const [space] = await db.insert(spaces).values({ name: "Discovery cost fixture" }).returning()
  if (!space) throw new Error("Missing fixture space")
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
      const measure = (mode: "individual" | "shared" | "batched") => measureOperation(db.$client.options, async () => {
        const discoveryWatermark = mode === "individual" ? undefined : await captureUpdateDiscoveryWatermark()
        const frontiers = mode === "batched" ? await loadRepairUserFrontiers(selected) : undefined
        // Match the repair service's eight active account scans, in one worker.
        let next = 0
        await Promise.all(Array.from({ length: Math.min(8, size) }, async () => {
          while (next < selected.length) {
            const userId = selected[next++]!
            const result = await getUpdatesState({ date: checkpoint }, {
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
      // Count all driver commands, including BEGIN/COMMIT and fence SQL.
      // Individual exclusive fences also contend with each other: failed
      // lock attempts add BEGIN/try/COMMIT retries, so their cost is a floor.
      expect(individual.sql.commands - shared.sql.commands).toBeGreaterThanOrEqual(4 * (size - 1))
      expect(shared.sql.commands).toBe(4 + (dirty ? 7 : 5) * size)
      expect(batched.sql.commands).toBe(4 + (dirty ? 5 : 3) * size + Math.ceil(size / 512))
      console.info(JSON.stringify({
        case: "dated-discovery-cost", users: size, dirty,
        individual: { commands: individual.sql.commands, sweepMs: individual.settledMs },
        shared: { commands: shared.sql.commands, sweepMs: shared.settledMs },
        batched: { commands: batched.sql.commands, sweepMs: batched.settledMs },
      }))
    }, 30_000)
  }
}

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
