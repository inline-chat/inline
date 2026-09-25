import { describe, expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { ConnectedUserRepair, emitUserHasNewUpdates, replayCurrentUserUpdate } from "./repair"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { postgresRepairDiscovery } from "./repairDiscovery.postgres"

setupTestLifecycle()

describe("connected user durable replay", () => {
  for (const tail of ["missing", "filtered"] as const) {
    test(`reconnects a legacy client when the durable ${tail} tail cannot carry recovery`, async () => {
      const user = await testUtils.createUser(`legacy-${tail}-tail@example.test`)
      await UserBucketUpdates.enqueue({ userId: user.id, update: {
        oneofKind: "userDialogArchived",
        userDialogArchived: { peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } }, archived: true },
      } })
      if (tail === "filtered") {
        await UserBucketUpdates.enqueue({ userId: user.id, update: {
          oneofKind: "userAddedToChat", userAddedToChat: { chatId: 2_000_000_001n },
        } })
      } else {
        await db.update(users).set({ updateSeq: 2 }).where(eq(users.id, user.id))
      }
      const push = spyOn(RealtimeUpdates, "pushToUserWithDelivery").mockResolvedValue(1)
      const closed: { reason: string; frontier?: number }[] = []
      const repair = new ConnectedUserRepair({
        discovery: postgresRepairDiscovery,
        connectedUserIds: () => [user.id], hasConnections: () => true, getConnectionEpoch: () => 1,
        emitUserHint: emitUserHasNewUpdates, replayCurrentUserUpdate,
        closeForUnrecoverableFrontier: (_id, reason, _epoch, frontier) => {
          closed.push({ reason, frontier })
          return 1
        },
        deliverTargetedBucketHint: async () => {},
      })
      try {
        await repair.start()
        for (let wave = 0; wave < 3; wave++) {
          repair.observeConnectedUsers()
          await repair.waitForIdle()
        }
        expect(closed).toEqual([{ reason: "no_replayable_record", frontier: 2 }])
        // The only emitted payload is the typed hint; no earlier record or
        // fabricated sequenced update pretends to represent the missing tail.
        expect(push.mock.calls.flatMap(([, batch]) => batch)).toEqual([{
          update: { oneofKind: "userHasNewUpdates", userHasNewUpdates: { updateSeq: 2 } },
        }])
      } finally {
        await repair.stop()
        push.mockRestore()
      }
    })
  }

  test("emits the current persisted user record rather than a synthetic wakeup", async () => {
    const user = await testUtils.createUser("repair-current-user-record@example.com")
    const persisted = await UserBucketUpdates.enqueue({
      userId: user.id,
      update: {
        oneofKind: "userDialogArchived",
        userDialogArchived: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } },
          archived: true,
        },
      },
    })
    const push = spyOn(RealtimeUpdates, "pushToUserWithDelivery").mockResolvedValue(1)
    try {
      expect(await replayCurrentUserUpdate(user.id, persisted.seq)).toBe("replayed")
      expect(push).toHaveBeenCalledTimes(1)
      const [recipient, updates] = push.mock.calls[0]!
      expect(recipient).toBe(user.id)
      expect(updates).toHaveLength(1)
      expect(updates[0]).toMatchObject({
        seq: persisted.seq,
        update: {
          oneofKind: "dialogArchived",
          dialogArchived: { archived: true },
        },
      })
    } finally {
      push.mockRestore()
    }
  })

  test("does not manufacture a replay when the requested frontier has no durable record", async () => {
    const user = await testUtils.createUser("repair-missing-user-record@example.com")
    const push = spyOn(RealtimeUpdates, "pushToUserWithDelivery").mockResolvedValue(1)
    try {
      expect(await replayCurrentUserUpdate(user.id, 1)).toBe("missing_record")
      expect(push).not.toHaveBeenCalled()
    } finally {
      push.mockRestore()
    }
  })

  test("sends a recipient-scoped user catch-up hint without creating a durable update", async () => {
    const user = await testUtils.createUser("repair-user-hint@example.com")
    const push = spyOn(RealtimeUpdates, "pushToUserWithDelivery").mockResolvedValue(1)
    try {
      expect(await emitUserHasNewUpdates(user.id, 23, () => true)).toBe(1)
      expect(push).toHaveBeenCalledWith(user.id, [{
        update: {
          oneofKind: "userHasNewUpdates",
          userHasNewUpdates: { updateSeq: 23 },
        },
      }])
    } finally {
      push.mockRestore()
    }
  })

  test("filters a stale private discovery record instead of replaying it", async () => {
    const user = await testUtils.createUser("repair-revoked-user-record@example.com")
    const persisted = await UserBucketUpdates.enqueue({
      userId: user.id,
      update: {
        oneofKind: "userAddedToChat",
        userAddedToChat: { chatId: 2_000_000_001n },
      },
    })
    const push = spyOn(RealtimeUpdates, "pushToUserWithDelivery").mockResolvedValue(1)
    try {
      expect(await replayCurrentUserUpdate(user.id, persisted.seq)).toBe("filtered_record")
      expect(push).not.toHaveBeenCalled()
    } finally {
      push.mockRestore()
    }
  })
})
