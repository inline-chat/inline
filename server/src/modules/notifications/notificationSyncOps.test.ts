import { describe, expect, it } from "bun:test"
import { randomUUID } from "node:crypto"
import { InternalMessagingService } from "@in/server/modules/internalMessaging/service"
import {
  NOTIFICATION_SYNC_OPS_MAX_ATTACHED,
  NOTIFICATION_SYNC_OPS_MAX_DELETED_IDS,
  NOTIFICATION_SYNC_OPS_MAX_ENTRIES,
  NOTIFICATION_SYNC_OPS_TTL_MS,
  NotificationSyncOpsTracker,
  type NotificationSyncOpsStore,
} from "./notificationSyncOps"

const redisUrl = process.env["INLINE_TEST_REDIS_URL"]

const fixedStore = (hash: Record<string, string> | undefined, flat = false): NotificationSyncOpsStore => ({
  command: async (name) => (name === "HGETALL" && hash ? (flat ? Object.entries(hash).flat() : hash) : undefined),
  key: (suffix) => `test:${suffix}`,
})

describe("notification sync ops", () => {
  it("returns nothing when the broker is unavailable or empty", async () => {
    expect(await new NotificationSyncOpsTracker(fixedStore(undefined)).recent(1)).toBeUndefined()
    expect(await new NotificationSyncOpsTracker(fixedStore({})).recent(1)).toBeUndefined()
    expect(await new NotificationSyncOpsTracker(fixedStore({}, true)).recent(1)).toBeUndefined()
  })

  it("reads both map and flat hash replies", async () => {
    const hash = { "r:chat_1": `${Date.now()}|41` }
    for (const flat of [false, true]) {
      expect((await new NotificationSyncOpsTracker(fixedStore(hash, flat)).recent(1))?.read).toEqual([{ threadId: "chat_1", upTo: "41" }])
    }
  })

  it("attaches the newest valid entries and skips expired or malformed ones", async () => {
    const now = 10 * NOTIFICATION_SYNC_OPS_TTL_MS
    const hash: Record<string, string> = {
      "r:chat_1": `${now - 1}|41`,
      "d:chat_2": `${now - 2}|7,x,8`,
      "r:chat_3": `${now - NOTIFICATION_SYNC_OPS_TTL_MS - 1}|99`,
      "r:chat_4": "garbage",
      "r:chat_5": `${now - 3}|0`,
    }
    for (let i = 0; i < NOTIFICATION_SYNC_OPS_MAX_ATTACHED; i++) hash[`r:old_${i}`] = `${now - 100 - i}|5`
    const ops = await new NotificationSyncOpsTracker(fixedStore(hash), () => now).recent(1)

    expect(ops?.read[0]).toEqual({ threadId: "chat_1", upTo: "41" })
    expect(ops?.deleted).toEqual([{ threadId: "chat_2", ids: ["7", "8"] }])
    expect(ops?.read.some((op) => op.threadId === "chat_3" || op.threadId === "chat_4" || op.threadId === "chat_5")).toBe(false)
    expect(ops!.read.length + ops!.deleted.length).toBe(NOTIFICATION_SYNC_OPS_MAX_ATTACHED - 1)
  })

  it.skipIf(!redisUrl)("keeps the highest read marker, appends deletes and trims the oldest threads", async () => {
    const service = new InternalMessagingService(redisUrl)
    try {
      await service.start()
      let now = Date.now()
      const tracker = new NotificationSyncOpsTracker(
        { command: (name, args) => service.sendCommand(name, args), key: (suffix) => service.key(suffix) },
        () => now,
      )
      const userId = Number.parseInt(randomUUID().slice(0, 8), 16)

      await tracker.recordRead(userId, "chat_1", "50")
      now++
      await tracker.recordRead(userId, "chat_1", "40")
      await tracker.recordDeleted(userId, "chat_2", ["1", "2"])
      now++
      await tracker.recordDeleted(userId, "chat_2", Array.from({ length: NOTIFICATION_SYNC_OPS_MAX_DELETED_IDS }, (_, i) => String(i + 3)))

      const ops = await tracker.recent(userId)
      expect(ops?.read).toEqual([{ threadId: "chat_1", upTo: "50" }])
      expect(ops?.deleted[0]?.ids).toHaveLength(NOTIFICATION_SYNC_OPS_MAX_DELETED_IDS)
      expect(ops?.deleted[0]?.ids.at(-1)).toBe(String(NOTIFICATION_SYNC_OPS_MAX_DELETED_IDS + 2))

      for (let i = 0; i < NOTIFICATION_SYNC_OPS_MAX_ENTRIES; i++) {
        now++
        await tracker.recordRead(userId, `chat_${100 + i}`, "1")
      }
      expect(await service.sendCommand("HLEN", [service.key(`notif-sync:${userId}`)])).toBe(NOTIFICATION_SYNC_OPS_MAX_ENTRIES)
      expect(await service.sendCommand("HEXISTS", [service.key(`notif-sync:${userId}`), "r:chat_1"])).toBe(0)
      await service.sendCommand("DEL", [service.key(`notif-sync:${userId}`)])
    } finally {
      await service.close()
    }
  })
})
