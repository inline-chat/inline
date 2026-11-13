import { describe, expect, spyOn, test } from "bun:test"
import { eq } from "drizzle-orm"
import type { Update } from "@inline-chat/protocol/core"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { UserSettingsModel } from "@in/server/db/models/userSettings/userSettings"
import { setFocusStatus } from "@in/server/functions/user.setFocusStatus"
import { updateUserSettings } from "@in/server/functions/user.updateUserSettings"
import { getChats } from "@in/server/functions/messages.getChats"
import * as transientRealtime from "@in/server/modules/internalMessaging/transient"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { clearUserSettingsCache } from "@in/server/modules/cache/userSettings"

const context = (userId: number) => ({ currentUserId: userId, currentSessionId: defaultTestContext.sessionId })

/** Focus each recipient was sent about `ownerId`; null means a status without Focus. */
const captureFocus = () => {
  const sent = new Map<number, boolean | null>()
  const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (userId: number, updates: Update[]) => {
    for (const update of updates) {
      if (update.update.oneofKind !== "updateUserStatus") continue
      sent.set(userId, update.update.updateUserStatus.status?.focus?.focused ?? null)
    }
  })
  const publish = spyOn(transientRealtime, "publishUserPresence").mockImplementation(() => {})
  return { sent, restore: () => { push.mockRestore(); publish.mockRestore() } }
}

const dmWith = async (owner: schema.DbUser, peer: schema.DbUser) => {
  const chat = await testUtils.createPrivateChat(owner, peer)
  await db.insert(schema.dialogs).values([
    { userId: owner.id, chatId: chat!.id, peerUserId: peer.id },
    { userId: peer.id, chatId: chat!.id, peerUserId: owner.id },
  ])
}

describe("Focus status", () => {
  setupTestLifecycle()

  test("reaches only allowed DM partners and a rule change clears removed ones", async () => {
    const owner = await testUtils.createUser("focus-owner@example.test")
    const trusted = await testUtils.createUser("focus-trusted@example.test")
    const other = await testUtils.createUser("focus-other@example.test")
    await dmWith(owner, trusted)
    await dmWith(owner, other)
    await UserSettingsModel.updateGeneralWithPatch(owner.id, {
      privacy: { focusStatus: { audience: "nobody", alwaysShare: [trusted.id] } },
    })
    clearUserSettingsCache()

    let capture = captureFocus()
    try {
      await setFocusStatus({ focused: true }, context(owner.id))
      expect(capture.sent).toEqual(new Map([[trusted.id, true]]))

      // An unchanged report soon after is not re-sent.
      capture.sent.clear()
      await setFocusStatus({ focused: true }, context(owner.id))
      expect(capture.sent.size).toBe(0)
    } finally {
      capture.restore()
    }

    capture = captureFocus()
    try {
      await updateUserSettings(
        { general: { privacy: { focusStatus: { audience: "nobody", alwaysShare: [] } } } },
        context(owner.id),
      )
      expect(capture.sent.get(trusted.id)).toBe(false)
      expect(capture.sent.get(other.id)).toBe(false)
    } finally {
      capture.restore()
    }
  })

  test("DM list carries each viewer's own Focus view and hides stale reports", async () => {
    const owner = await testUtils.createUser("focus-list-owner@example.test")
    const trusted = await testUtils.createUser("focus-list-trusted@example.test")
    const other = await testUtils.createUser("focus-list-other@example.test")
    await dmWith(owner, trusted)
    await dmWith(owner, other)
    await UserSettingsModel.updateGeneralWithPatch(owner.id, {
      privacy: { focusStatus: { audience: "nobody", alwaysShare: [trusted.id] } },
    })
    clearUserSettingsCache()
    await db.update(schema.users).set({ focused: true, focusUpdatedAt: new Date() }).where(eq(schema.users.id, owner.id))

    const focusSeenBy = async (viewerId: number) => {
      const result = await getChats({}, context(viewerId))
      return result.users.find((user) => Number(user.id) === owner.id)?.status?.focus?.focused
    }

    expect(await focusSeenBy(trusted.id)).toBe(true)
    expect(await focusSeenBy(other.id)).toBe(false)

    await db
      .update(schema.users)
      .set({ focusUpdatedAt: new Date(Date.now() - 25 * 60 * 60 * 1000) })
      .where(eq(schema.users.id, owner.id))
    expect(await focusSeenBy(trusted.id)).toBe(false)
  })
})
