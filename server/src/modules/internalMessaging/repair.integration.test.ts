import { describe, expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { emitUserHasNewUpdates, replayCurrentUserUpdate } from "./repair"

setupTestLifecycle()

describe("connected user durable replay", () => {
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
