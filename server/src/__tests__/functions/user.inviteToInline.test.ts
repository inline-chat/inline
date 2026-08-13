import { describe, expect, mock, test } from "bun:test"
import type { InviteToInlineInput } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { dialogs, users } from "@in/server/db/schema"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { InviteDeliveryGuard, inviteToInline } from "@in/server/functions/user.inviteToInline"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const context = (userId: number) => ({ currentUserId: userId, currentSessionId: 1 })

const isolatedOptions = (deliver = mock(async () => {}), nowMs: () => number = Date.now) => ({
  requestLimiter: new InMemoryRateLimiter(),
  deliveryGuard: new InviteDeliveryGuard(),
  deliver,
  nowMs,
})

const chatUpdatesInput = (peerUserId: number) => ({
  bucket: {
    type: {
      oneofKind: "chat" as const,
      chat: {
        peerId: {
          type: {
            oneofKind: "user" as const,
            user: { userId: BigInt(peerUserId) },
          },
        },
      },
    },
  },
  startSeq: 0n,
  seqEnd: 0n,
  totalLimit: 1000,
  limit: 1000,
})

describe("inviteToInline", () => {
  setupTestLifecycle()

  test("creates a private chat while returning only public user fields", async () => {
    const inviter = await testUtils.createUser("inline-inviter@example.com")
    const invitee = await testUtils.createUser("inline-invitee@example.com")
    await db.update(users).set({ firstName: "Invitee", username: "invitee" }).where(eq(users.id, invitee.id))

    const input: InviteToInlineInput = {
      via: { oneofKind: "userId", userId: BigInt(invitee.id) },
    }
    const result = await inviteToInline(input, context(inviter.id), isolatedOptions())
    if (!result.user || !result.chat || !result.dialog) throw new Error("missing invite projection")

    expect(result.user.id).toBe(BigInt(invitee.id))
    expect(result.user.firstName).toBe("Invitee")
    expect(result.user.username).toBe("invitee")
    expect(result.user.min).toBe(true)
    expect(result.user.email).toBeUndefined()
    expect(result.user.phoneNumber).toBeUndefined()
    expect(result.user.pendingSetup).toBeUndefined()
    expect(result.chat.id).toBeGreaterThan(0n)
    expect(result.dialog.peer?.type.oneofKind).toBe("user")

    const catchup = await getUpdates(chatUpdatesInput(invitee.id), context(inviter.id))
    const newChat = catchup.updates.find((update) => update.update.oneofKind === "newChat")
    if (newChat?.update.oneofKind !== "newChat") throw new Error("missing direct-invite catch-up update")
    expect(newChat.update.newChat.user?.username).toBe("invitee")
  })

  test("keeps contact profile data opaque in the response, live update, and catch-up", async () => {
    const inviter = await testUtils.createUser("inline-contact-inviter@example.com")
    const invitee = await testUtils.createUser("inline-existing-contact@example.com")
    await db.update(users).set({ firstName: "Existing", username: "existing-contact" }).where(eq(users.id, invitee.id))
    await db.update(users).set({ firstName: "Inviter" }).where(eq(users.id, inviter.id))

    const pushed = mock(RealtimeUpdates.pushToUser)
    const originalPushToUser = RealtimeUpdates.pushToUser
    RealtimeUpdates.pushToUser = pushed

    let result
    try {
      result = await inviteToInline(
        { via: { oneofKind: "email", email: "INLINE-EXISTING-CONTACT@example.com" } },
        context(inviter.id),
        isolatedOptions(),
      )
      await Bun.sleep(0)
    } finally {
      RealtimeUpdates.pushToUser = originalPushToUser
    }

    expect(result.user).toEqual({ id: BigInt(invitee.id), min: true })
    const inviterUpdate = pushed.mock.calls
      .filter(([userId]) => userId === inviter.id)
      .flatMap(([, updates]) => updates)
      .find((update) => update.update.oneofKind === "newChat")
    expect(inviterUpdate?.update.oneofKind).toBe("newChat")
    if (inviterUpdate?.update.oneofKind !== "newChat") throw new Error("missing inviter newChat update")
    expect(inviterUpdate.update.newChat.user).toEqual({ id: BigInt(invitee.id), min: true })

    const inviterCatchup = await getUpdates(chatUpdatesInput(invitee.id), context(inviter.id))
    const caughtUpChat = inviterCatchup.updates.find((update) => update.update.oneofKind === "newChat")
    if (caughtUpChat?.update.oneofKind !== "newChat") throw new Error("missing inviter catch-up update")
    expect(caughtUpChat.update.newChat.user).toEqual({ id: BigInt(invitee.id), min: true })
    expect(inviterCatchup.sidecars?.users.map((user) => user.id)).not.toContain(BigInt(invitee.id))

    const inviteeCatchup = await getUpdates(chatUpdatesInput(inviter.id), context(invitee.id))
    const inviteeChat = inviteeCatchup.updates.find((update) => update.update.oneofKind === "newChat")
    if (inviteeChat?.update.oneofKind !== "newChat") throw new Error("missing invitee catch-up update")
    expect(inviteeChat.update.newChat.user?.firstName).toBe("Inviter")
  })

  test("reuses the pending identity and private chat for concurrent email invites", async () => {
    const inviter = await testUtils.createUser("inline-repeat-inviter@example.com")
    const input: InviteToInlineInput = {
      via: { oneofKind: "email", email: "inline-pending@example.com" },
    }
    const deliver = mock(async () => {})
    const options = isolatedOptions(deliver)

    const [first, second] = await Promise.all([
      inviteToInline(input, context(inviter.id), options),
      inviteToInline(input, context(inviter.id), options),
    ])
    if (!first.user || !first.chat || !second.user || !second.chat) throw new Error("missing invite projection")

    expect(second.user.id).toBe(first.user.id)
    expect(second.chat.id).toBe(first.chat.id)
    expect(first.user).toEqual({ id: first.user.id, min: true })
    expect(second.user).toEqual({ id: first.user.id, min: true })
    expect(deliver).toHaveBeenCalledTimes(1)
    const pending = (await db.select().from(users).where(eq(users.id, Number(first.user.id))).limit(1))[0]
    expect(pending?.pendingSetup).toBe(true)
    expect(await db.select().from(dialogs).where(eq(dialogs.chatId, Number(first.chat.id)))).toHaveLength(2)
  })

  test("returns the real unread count when reusing an existing private chat", async () => {
    const inviter = await testUtils.createUser("inline-unread-inviter@example.com")
    const invitee = await testUtils.createUser("inline-unread-invitee@example.com")
    const input: InviteToInlineInput = { via: { oneofKind: "userId", userId: BigInt(invitee.id) } }
    const options = isolatedOptions()

    const first = await inviteToInline(input, context(inviter.id), options)
    await testUtils.createTestMessage({
      messageId: 1,
      chatId: Number(first.chat?.id),
      fromId: invitee.id,
      text: "Unread",
    })

    const second = await inviteToInline(input, context(inviter.id), options)
    expect(second.dialog?.unreadCount).toBe(1)
  })

  test("limits callers and suppresses repeated delivery during the cooldown", async () => {
    const inviter = await testUtils.createUser("inline-limited-inviter@example.com")
    const input: InviteToInlineInput = {
      via: { oneofKind: "email", email: "inline-limited-target@example.com" },
    }
    const deliver = mock(async () => {})
    let now = Date.now()
    const options = isolatedOptions(deliver, () => now)

    for (let request = 0; request < 20; request += 1) {
      await inviteToInline(input, context(inviter.id), options)
    }
    expect(deliver).toHaveBeenCalledTimes(1)

    await expect(inviteToInline(input, context(inviter.id), options)).rejects.toMatchObject({ codeNumber: 429 })

    now += 60 * 60_000 + 1
    await inviteToInline(input, context(inviter.id), options)
    expect(deliver).toHaveBeenCalledTimes(2)
  })

  test("allows delivery to retry after a handoff failure", async () => {
    const guard = new InviteDeliveryGuard()
    let attempts = 0

    await expect(
      guard.run({
        key: "retry",
        nowMs: 1,
        deliver: async () => {
          attempts += 1
          throw new Error("handoff failed")
        },
      }),
    ).rejects.toThrow("handoff failed")

    await expect(
      guard.run({
        key: "retry",
        nowMs: 2,
        deliver: async () => {
          attempts += 1
        },
      }),
    ).resolves.toBe(true)
    expect(attempts).toBe(2)
  })

  test("does not create a self invitation", async () => {
    const inviter = await testUtils.createUser("inline-self@example.com")
    await expect(
      inviteToInline(
        { via: { oneofKind: "userId", userId: BigInt(inviter.id) } },
        context(inviter.id),
        isolatedOptions(),
      ),
    ).rejects.toMatchObject({ codeNumber: 400 })
  })
})
