import { describe, expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { handler as leaveSpace } from "@in/server/methods/leaveSpace"
import { handler as deleteSpace } from "@in/server/methods/deleteSpace"
import { UpdatesModel } from "@in/server/db/models/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import {
  activateCommittedSpaceMembership,
  deactivateCommittedSpaceMembership,
} from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

const makeContext = (userId: number): HandlerContext => ({
  currentUserId: userId,
  currentSessionId: 1,
  ip: "127.0.0.1",
})

describe("space exit updates", () => {
  setupTestLifecycle()

  test("failed authority recheck drops cached fanout without publishing an uncertain eviction", async () => {
    const user = await testUtils.createUser("space-recheck-failure@example.com")
    const space = await testUtils.createSpace("Space Recheck Failure")
    if (!space) throw new Error("Expected Space")
    connectionManager.subscribeToSpace(user.id, space.id)
    AccessGuardsCache.setSpaceMember(space.id, user.id)
    const transaction = spyOn(db, "transaction").mockRejectedValueOnce(new Error("injected authority outage"))
    let evictionPublished = false
    try {
      await expect(deactivateCommittedSpaceMembership({
        userId: user.id,
        spaceId: space.id,
        memberId: 1,
      }, () => {
        evictionPublished = true
        return undefined
      })).rejects.toThrow("injected authority outage")
      expect(connectionManager.getSpaceUserIds(space.id)).not.toContain(user.id)
      expect(AccessGuardsCache.getSpaceMember(space.id, user.id)).toBeUndefined()
      expect(evictionPublished).toBe(false)
    } finally {
      transaction.mockRestore()
    }
  })

  test("leaving persists independent Space and User removals and fans out only valid sequences", async () => {
    const owner = await testUtils.createUser("space-leave-owner@example.com")
    const leaver = await testUtils.createUser("space-leave-member@example.com")
    const remaining = await testUtils.createUser("space-leave-remaining@example.com")
    const outsider = await testUtils.createUser("space-leave-outsider@example.com")
    const space = await testUtils.createSpace("Space Leave Updates")
    if (!space) throw new Error("Failed to create Space")
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: leaver.id, role: "member" },
      { spaceId: space.id, userId: remaining.id, role: "member" },
    ])
    const [leaverMembership] = await db
      .select({ id: schema.members.id })
      .from(schema.members)
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, leaver.id)))
      .limit(1)
    if (!leaverMembership) throw new Error("Expected leaver membership")
    const privateChat = await testUtils.createChat(space.id, "Retained leave chat", "thread", false)
    if (!privateChat) throw new Error("Failed to create private chat")
    await db.insert(schema.chatParticipants).values({ chatId: privateChat.id, userId: leaver.id })

    const previousUserUpdate = await UserBucketUpdates.enqueue({
      userId: leaver.id,
      update: {
        oneofKind: "userSpaceMemberDelete",
        userSpaceMemberDelete: { spaceId: BigInt(space.id + 1) },
      },
    })
    connectionManager.subscribeToSpace(leaver.id, space.id)
    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await leaveSpace({ spaceId: space.id }, makeContext(leaver.id))

      const durableUserRows = await db
        .select()
        .from(schema.updates)
        .where(and(
          eq(schema.updates.bucket, schema.UpdateBucket.User),
          eq(schema.updates.entityId, leaver.id),
        ))
      const userRemoval = durableUserRows
        .map(UpdatesModel.decrypt)
        .find((row) =>
          row.payload.update.oneofKind === "userSpaceMemberDelete"
          && row.payload.update.userSpaceMemberDelete.spaceId === BigInt(space.id)
        )
      expect(userRemoval?.payload.update).toEqual({
        oneofKind: "userSpaceMemberDelete",
        userSpaceMemberDelete: { spaceId: BigInt(space.id) },
      })

      const durableSpaceRows = await db
        .select()
        .from(schema.updates)
        .where(and(
          eq(schema.updates.bucket, schema.UpdateBucket.Space),
          eq(schema.updates.entityId, space.id),
        ))
      const spaceRemoval = durableSpaceRows
        .map(UpdatesModel.decrypt)
        .find((row) => row.payload.update.oneofKind === "spaceRemoveMember")
      if (!spaceRemoval) throw new Error("Expected durable Space removal")
      expect(spaceRemoval.payload.update).toEqual({
        oneofKind: "spaceRemoveMember",
        spaceRemoveMember: {
          spaceId: BigInt(space.id),
          userId: BigInt(leaver.id),
          memberId: BigInt(leaverMembership.id),
        },
      })
      expect(userRemoval?.seq).toBe(previousUserUpdate.seq + 1)

      const pushes = push.mock.calls.flatMap(([recipientUserId, updates]) =>
        updates
          .filter((update) => update.update.oneofKind === "spaceMemberDelete")
          .map((update) => ({ recipientUserId, seq: update.seq })),
      )
      expect(pushes.map(({ recipientUserId, seq }) => `${recipientUserId}:${seq ?? "unsequenced"}`).sort())
        .toEqual([
          `${owner.id}:${spaceRemoval.seq}`,
          `${remaining.id}:${spaceRemoval.seq}`,
          `${leaver.id}:unsequenced`,
        ].sort())
      expect(pushes.some(({ recipientUserId }) => recipientUserId === outsider.id)).toBe(false)
      expect(connectionManager.getSpaceUserIds(space.id)).not.toContain(leaver.id)
      expect(await db.select().from(schema.members).where(and(
        eq(schema.members.spaceId, space.id),
        eq(schema.members.userId, leaver.id),
      ))).toEqual([])
      expect(await db.select().from(schema.chatParticipants).where(and(
        eq(schema.chatParticipants.chatId, privateChat.id),
        eq(schema.chatParticipants.userId, leaver.id),
      ))).toHaveLength(1)
      // A stale positive cache or retained participant row is not authority.
      AccessGuardsCache.setSpaceMember(space.id, leaver.id)
      await expect(AccessGuards.ensureChatAccess(privateChat, leaver.id)).rejects.toMatchObject({
        code: RealtimeRpcError.Code.SPACE_ID_INVALID,
      })
      const batchAccess = await db.transaction((tx) =>
        getEffectiveChatAccessUserIds(tx, [privateChat.id], { userIds: [leaver.id] }),
      )
      expect(batchAccess.get(privateChat.id)?.has(leaver.id)).toBe(false)
    } finally {
      push.mockRestore()
    }
  })

  test("deleting emits one durable User eviction per member without inventing a Space sequence or sweeping chats", async () => {
    const owner = await testUtils.createUser("space-delete-owner@example.com")
    const member = await testUtils.createUser("space-delete-member@example.com")
    const outsider = await testUtils.createUser("space-delete-outsider@example.com")
    const space = await testUtils.createSpace("Space Delete Updates")
    if (!space) throw new Error("Failed to create Space")
    await db.update(schema.spaces).set({ creatorId: owner.id }).where(eq(schema.spaces.id, space.id))
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: member.id, role: "member" },
    ])
    const chat = await testUtils.createChat(space.id, "Retained after Space delete", "thread", false)
    if (!chat) throw new Error("Failed to create chat")
    await db.insert(schema.chatParticipants).values({ chatId: chat.id, userId: member.id })
    await db.insert(schema.dialogs).values({ chatId: chat.id, userId: member.id, spaceId: space.id })

    connectionManager.subscribeToSpace(owner.id, space.id)
    connectionManager.subscribeToSpace(member.id, space.id)
    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await deleteSpace({ spaceId: space.id }, makeContext(owner.id))

      const [deletedSpace] = await db.select().from(schema.spaces).where(eq(schema.spaces.id, space.id))
      expect(deletedSpace?.deleted).toBeInstanceOf(Date)
      expect(await db.select().from(schema.members).where(eq(schema.members.spaceId, space.id))).toEqual([])

      const durableSpaceRows = await db.select().from(schema.updates).where(and(
        eq(schema.updates.bucket, schema.UpdateBucket.Space),
        eq(schema.updates.entityId, space.id),
      ))
      expect(durableSpaceRows).toEqual([])

      for (const userId of [owner.id, member.id]) {
        const rows = await db.select().from(schema.updates).where(and(
          eq(schema.updates.bucket, schema.UpdateBucket.User),
          eq(schema.updates.entityId, userId),
        ))
        const removals = rows
          .map(UpdatesModel.decrypt)
          .filter((row) => row.payload.update.oneofKind === "userSpaceMemberDelete")
        expect(removals).toHaveLength(1)
        expect(removals[0]?.payload.update).toEqual({
          oneofKind: "userSpaceMemberDelete",
          userSpaceMemberDelete: { spaceId: BigInt(space.id) },
        })
      }
      const outsiderRows = await db.select().from(schema.updates).where(and(
        eq(schema.updates.bucket, schema.UpdateBucket.User),
        eq(schema.updates.entityId, outsider.id),
      ))
      expect(outsiderRows).toEqual([])

      const pushes = push.mock.calls.flatMap(([recipientUserId, updates]) =>
        updates
          .filter((update) => update.update.oneofKind === "spaceMemberDelete")
          .map((update) => ({ recipientUserId, seq: update.seq })),
      )
      expect(pushes.map(({ recipientUserId, seq }) => `${recipientUserId}:${seq ?? "unsequenced"}`).sort())
        .toEqual([`${owner.id}:unsequenced`, `${member.id}:unsequenced`].sort())
      expect(connectionManager.getSpaceUserIds(space.id)).not.toContain(owner.id)
      expect(connectionManager.getSpaceUserIds(space.id)).not.toContain(member.id)

      // Space deletion retires authority; it does not enumerate every thread
      // and destroy cached history or dialog rows during the sync transition.
      expect(await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))).toHaveLength(1)
      expect(await db.select().from(schema.chatParticipants).where(eq(schema.chatParticipants.chatId, chat.id)))
        .toHaveLength(1)
      expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, chat.id))).toHaveLength(1)

      // Even a malformed late writer recreating a retained membership row
      // cannot turn a soft-deleted Space back into chat authority.
      await db.insert(schema.members).values({ spaceId: space.id, userId: member.id, role: "member" })
      AccessGuardsCache.setSpaceMember(space.id, member.id)
      await expect(AccessGuards.ensureChatAccess(chat, member.id)).rejects.toMatchObject({
        code: RealtimeRpcError.Code.SPACE_ID_INVALID,
      })
      const batchAccess = await db.transaction((tx) =>
        getEffectiveChatAccessUserIds(tx, [chat.id], { userIds: [member.id] }),
      )
      expect(batchAccess.get(chat.id)?.has(member.id)).toBe(false)
    } finally {
      push.mockRestore()
    }
  })

  test("a delayed leave side effect cannot unsubscribe or evict a newer membership generation", async () => {
    const user = await testUtils.createUser("space-generation-member@example.com")
    const space = await testUtils.createSpace("Space Membership Generation")
    if (!space) throw new Error("Failed to create Space")
    const [oldMember] = await db
      .insert(schema.members)
      .values({ spaceId: space.id, userId: user.id, role: "member" })
      .returning()
    if (!oldMember) throw new Error("Failed to create old membership")
    const session = await testUtils.createSessionForUser(user.id)
    const connectionId = `space-generation-${user.id}`
    connectionManager.addConnection({
      id: connectionId,
      close: () => {},
      subscribe: () => {},
      raw: { sendBinary: () => {} },
    } as unknown as Parameters<typeof connectionManager.addConnection>[0], ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(connectionId, user.id, session.session.id)

    try {
      expect(await activateCommittedSpaceMembership({
        spaceId: space.id,
        userId: user.id,
        memberId: oldMember.id,
      })).toBe(true)
      expect(connectionManager.getSpaceUserIds(space.id)).toContain(user.id)

      await db.delete(schema.members).where(eq(schema.members.id, oldMember.id))
      // A stale add may notice removal before its real callback. That local
      // unsubscribe must not suppress the later authoritative eviction event.
      expect(await activateCommittedSpaceMembership({
        spaceId: space.id,
        userId: user.id,
        memberId: oldMember.id,
      })).toBe(false)
      let removalPublications = 0
      expect(await deactivateCommittedSpaceMembership({
        spaceId: space.id,
        userId: user.id,
        memberId: oldMember.id,
      }, () => {
        removalPublications += 1
        return undefined
      })).toBe(true)
      expect(removalPublications).toBe(1)
      expect(connectionManager.getSpaceUserIds(space.id)).not.toContain(user.id)

      const [newMember] = await db
        .insert(schema.members)
        .values({ spaceId: space.id, userId: user.id, role: "member" })
        .returning()
      if (!newMember) throw new Error("Failed to create replacement membership")
      expect(newMember.id).toBeGreaterThan(oldMember.id)

      // A duplicate stale leave completion runs before the re-invite's own
      // post-commit callback. Its DB recheck activates the winner and suppresses
      // removal even though the new add callback has not run yet.
      expect(await deactivateCommittedSpaceMembership({
        spaceId: space.id,
        userId: user.id,
        memberId: oldMember.id,
      })).toBe(false)
      expect(connectionManager.getSpaceUserIds(space.id)).toContain(user.id)

      expect(await activateCommittedSpaceMembership({
        spaceId: space.id,
        userId: user.id,
        memberId: newMember.id,
      })).toBe(true)
      expect(connectionManager.getSpaceUserIds(space.id)).toContain(user.id)
    } finally {
      connectionManager.removeConnection(connectionId)
    }
  })
})
