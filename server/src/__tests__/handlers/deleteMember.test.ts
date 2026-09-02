import { describe, expect, test, beforeEach, spyOn } from "bun:test"
import { deleteMemberHandler } from "../../realtime/handlers/space.deleteMember"
import { setupTestLifecycle, testUtils } from "../setup"
import { db, schema } from "../../db"
import type { HandlerContext } from "../../realtime/types"
import type { DeleteMemberInput } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import type { DbSpace, DbUser } from "@in/server/db/schema"
import { createGridRoom, getGrid, joinGridRoom } from "@in/server/functions/grid"
import { toggleSpaceGrid } from "@in/server/functions/space.settings"
import { joinPublicSpace } from "@in/server/functions/space.joinPublicSpace"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import { UpdatesModel } from "@in/server/db/models/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { addSpaceMember } from "@in/server/functions/space.addMember.shared"
import * as membershipLifecycle from "@in/server/modules/authorization/spaceMembershipLifecycle"
import * as realtimeMessages from "@in/server/realtime/message"

describe("deleteMemberHandler", () => {
  setupTestLifecycle()

  let adminUser: DbUser
  let memberUser: DbUser
  let space: DbSpace
  let handlerContext: HandlerContext
  let privateThreadId: number

  beforeEach(async () => {
    // Create users
    adminUser = (await testUtils.createUser("admin@example.com"))!
    memberUser = (await testUtils.createUser("member@example.com"))!

    // Create space
    space = (await testUtils.createSpace("Delete Member Test Space"))!

    // Add members: admin (owner) and regular member
    await db
      .insert(schema.members)
      .values({
        userId: adminUser.id,
        spaceId: space.id,
        role: "owner" as const,
      })
      .execute()

    await db
      .insert(schema.members)
      .values({
        userId: memberUser.id,
        spaceId: space.id,
        role: "member" as const,
      })
      .execute()

    // Create a private thread in the space with both users as participants + dialogs
    const [thread] = await db
      .insert(schema.chats)
      .values({
        type: "thread" as const,
        title: "Private Thread",
        spaceId: space.id,
        publicThread: false,
      })
      .returning()

    privateThreadId = thread!.id

    await db
      .insert(schema.chatParticipants)
      .values([
        { chatId: privateThreadId, userId: adminUser.id },
        { chatId: privateThreadId, userId: memberUser.id },
      ])
      .execute()

    await db
      .insert(schema.dialogs)
      .values([
        { chatId: privateThreadId, userId: adminUser.id, spaceId: space.id },
        { chatId: privateThreadId, userId: memberUser.id, spaceId: space.id },
      ])
      .execute()

    // Prepare handler context for admin user
    handlerContext = {
      userId: adminUser.id,
      sessionId: 456,
      connectionId: "test-connection",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }
  })

  test("should delete a member from space and return updates", async () => {
    const input: DeleteMemberInput = {
      spaceId: BigInt(space.id),
      userId: BigInt(memberUser.id),
      blockJoin: false,
    }

    const result = await deleteMemberHandler(input, handlerContext)

    expect(result.updates).toBeDefined()
    expect(result.updates.length).toBeGreaterThan(0)

    const deleteUpdate = result.updates.find((u) => u.update?.oneofKind === "spaceMemberDelete")
    expect(deleteUpdate).toBeDefined()

    const spaceMemberDelete =
      deleteUpdate?.update?.oneofKind === "spaceMemberDelete"
        ? deleteUpdate.update.spaceMemberDelete
        : undefined
    expect(spaceMemberDelete?.userId).toBe(BigInt(memberUser.id))
    expect(spaceMemberDelete?.spaceId).toBe(BigInt(space.id))

    let membersMatching = await db
      .select()
      .from(schema.members)
      .where(and(eq(schema.members.userId, memberUser.id), eq(schema.members.spaceId, space.id)))
    expect(membersMatching.length).toBe(0)
  })

  test("immediately removes the former member from Space fanout", async () => {
    connectionManager.subscribeToSpace(memberUser.id, space.id)
    expect(connectionManager.getSpaceUserIds(space.id)).toContain(memberUser.id)

    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
      handlerContext,
    )

    expect(connectionManager.getSpaceUserIds(space.id)).not.toContain(memberUser.id)
  })

  test("a re-add before delayed removal publication suppresses the old eviction and Grid revoke", async () => {
    const session = await testUtils.createSessionForUser(memberUser.id)
    const connectionId = `delayed-removal-${memberUser.id}`
    connectionManager.addConnection({
      id: connectionId,
      close: () => {},
      subscribe: () => {},
      raw: { sendBinary: () => {} },
    } as unknown as Parameters<typeof connectionManager.addConnection>[0], ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(connectionId, memberUser.id, session.session.id)
    const originalDeactivate = membershipLifecycle.deactivateCommittedSpaceMembership
    let readdedMemberId: number | undefined
    const deactivate = spyOn(membershipLifecycle, "deactivateCommittedSpaceMembership").mockImplementation(
      async (input, publishRemoval) => {
        if (input.userId === memberUser.id && readdedMemberId === undefined) {
          // The original removal has committed, but its post-commit callback
          // has not checked authority or touched the connection projection yet.
          const readded = await addSpaceMember({
            spaceId: space.id,
            actorUserId: adminUser.id,
            target: { kind: "userId", userId: memberUser.id },
            admission: "manageMembers",
          })
          readdedMemberId = readded.member.id
        }
        return originalDeactivate(input, publishRemoval)
      },
    )
    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    const send = spyOn(realtimeMessages, "sendMessageToRealtimeUser").mockResolvedValue(undefined)
    try {
      await deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
        handlerContext,
      )

      expect(readdedMemberId).toBeDefined()
      expect(connectionManager.getSpaceUserIds(space.id)).toContain(memberUser.id)
      const targetUpdates = push.mock.calls
        .filter(([userId]) => userId === memberUser.id)
        .flatMap(([, updates]) => updates)
      expect(targetUpdates.some((update) => update.update.oneofKind === "joinSpace")).toBe(true)
      expect(targetUpdates.some((update) =>
        update.update.oneofKind === "spaceMemberDelete" && update.seq === undefined,
      )).toBe(false)
      expect(send.mock.calls.some(([userId, payload]) =>
        userId === memberUser.id
        && payload.oneofKind === "grid"
        && payload.grid.event.oneofKind === "accessRevoked",
      )).toBe(false)
    } finally {
      deactivate.mockRestore()
      push.mockRestore()
      send.mockRestore()
      connectionManager.removeConnection(connectionId)
    }
  })

  test("persists removal independently in the Space and removed-user buckets", async () => {
    const priorUserUpdate = await UserBucketUpdates.enqueue({
      userId: memberUser.id,
      update: {
        oneofKind: "userSpaceMemberDelete",
        userSpaceMemberDelete: { spaceId: BigInt(space.id + 1) },
      },
    })

    const result = await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
      handlerContext,
    )
    const returnedRemoval = result.updates.find((update) => update.update.oneofKind === "spaceMemberDelete")
    if (!returnedRemoval?.seq) throw new Error("Expected sequenced Space removal")

    const durableRows = await db
      .select()
      .from(schema.updates)
      .where(
        and(
          eq(schema.updates.entityId, memberUser.id),
          eq(schema.updates.bucket, schema.UpdateBucket.User),
        ),
      )
      .orderBy(schema.updates.seq)
    const durableUserRemoval = durableRows
      .map(UpdatesModel.decrypt)
      .find((row) =>
        row.payload.update.oneofKind === "userSpaceMemberDelete"
        && row.payload.update.userSpaceMemberDelete.spaceId === BigInt(space.id)
      )
    if (!durableUserRemoval) throw new Error("Expected durable removed-user update")

    const [durableSpaceRemovalRow] = await db
      .select()
      .from(schema.updates)
      .where(
        and(
          eq(schema.updates.entityId, space.id),
          eq(schema.updates.bucket, schema.UpdateBucket.Space),
          eq(schema.updates.seq, returnedRemoval.seq),
        ),
      )
      .limit(1)
    if (!durableSpaceRemovalRow) throw new Error("Expected durable Space removal")
    const durableSpaceRemoval = UpdatesModel.decrypt(durableSpaceRemovalRow)

    expect(durableSpaceRemoval.payload.update.oneofKind).toBe("spaceRemoveMember")
    expect(durableUserRemoval.seq).toBe(priorUserUpdate.seq + 1)
    expect(durableUserRemoval.seq).not.toBe(durableSpaceRemoval.seq)
  })

  test("fans out the Space sequence only to members who retain Space access", async () => {
    const remainingMember = await testUtils.createUser(`remaining-member-${space.id}@example.com`)
    const outsider = await testUtils.createUser(`delete-member-outsider-${space.id}@example.com`)
    if (!remainingMember || !outsider) throw new Error("Fanout users not created")
    await db.insert(schema.members).values({
      userId: remainingMember.id,
      spaceId: space.id,
      role: "member",
    })

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      const result = await deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
        handlerContext,
      )
      const returnedRemoval = result.updates.find((update) => update.update.oneofKind === "spaceMemberDelete")
      if (!returnedRemoval?.seq) throw new Error("Expected sequenced Space removal")

      const removalPushes = push.mock.calls.flatMap(([recipientUserId, updates]) =>
        updates
          .filter((update) => update.update.oneofKind === "spaceMemberDelete")
          .map((update) => ({ recipientUserId, seq: update.seq })),
      )

      expect(
        removalPushes
          .map(({ recipientUserId, seq }) => `${recipientUserId}:${seq ?? "unsequenced"}`)
          .sort(),
      ).toEqual([
        `${adminUser.id}:${returnedRemoval.seq}`,
        `${memberUser.id}:unsequenced`,
        `${remainingMember.id}:${returnedRemoval.seq}`,
      ].sort())
      expect(removalPushes.some(({ recipientUserId }) => recipientUserId === outsider.id)).toBe(false)
    } finally {
      push.mockRestore()
    }
  })

  test("queues self-removal eviction but does not repeat it in a potentially delayed RPC reply", async () => {
    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      const result = await deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(adminUser.id), blockJoin: false },
        handlerContext,
      )

      expect(result.updates).toEqual([])
      const selfEvictions = push.mock.calls
        .filter(([userId]) => userId === adminUser.id)
        .flatMap(([, updates]) => updates)
        .filter((update) => update.update.oneofKind === "spaceMemberDelete")
      expect(selfEvictions).toHaveLength(1)
      expect(selfEvictions[0]?.seq).toBeUndefined()
    } finally {
      push.mockRestore()
    }

    const durableSpaceRows = await db
      .select()
      .from(schema.updates)
      .where(
        and(
          eq(schema.updates.bucket, schema.UpdateBucket.Space),
          eq(schema.updates.entityId, space.id),
        ),
      )
    const durableRemoval = durableSpaceRows
      .map(UpdatesModel.decrypt)
      .find((row) => row.payload.update.oneofKind === "spaceRemoveMember")
    expect(durableRemoval?.seq).toBeGreaterThan(0)
  })

  test("does not report failure when the post-commit access-revoked push fails", async () => {
    const memberSession = await testUtils.createSessionForUser(memberUser.id)
    const connectionId = `failing-grid-revocation-${memberUser.id}`
    let sendCount = 0
    const ws = {
      id: connectionId,
      close: () => {},
      subscribe: () => {},
      raw: {
        sendBinary: () => {
          sendCount += 1
          if (sendCount === 1) {
            throw new Error("socket closed during Grid revocation")
          }
        },
      },
    } as unknown as Parameters<typeof connectionManager.addConnection>[0]
    connectionManager.addConnection(ws, ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(connectionId, memberUser.id, memberSession.session.id)

    try {
      await expect(
        deleteMemberHandler(
          { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
          handlerContext,
        ),
      ).resolves.toBeDefined()

      const membership = await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.userId, memberUser.id), eq(schema.members.spaceId, space.id)))
      expect(membership).toEqual([])
    } finally {
      connectionManager.removeConnection(connectionId)
    }
  })

  test("removes user from private threads and dialogs in the space", async () => {
    const input: DeleteMemberInput = {
      spaceId: BigInt(space.id),
      userId: BigInt(memberUser.id),
      blockJoin: false,
    }

    await deleteMemberHandler(input, handlerContext)

    const participants = await db
      .select()
      .from(schema.chatParticipants)
      .where(
        and(eq(schema.chatParticipants.chatId, privateThreadId), eq(schema.chatParticipants.userId, memberUser.id)),
      )
    expect(participants.length).toBe(0)

    const memberDialogs = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, privateThreadId), eq(schema.dialogs.userId, memberUser.id)))
    expect(memberDialogs.length).toBe(0)

    const adminDialogs = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, privateThreadId), eq(schema.dialogs.userId, adminUser.id)))
    expect(adminDialogs.length).toBe(1)
  })

  test("removes descendant chat grants while keeping durable access events root-only", async () => {
    await db.insert(schema.messages).values({
      chatId: privateThreadId,
      messageId: 1,
      fromId: adminUser.id,
      text: "anchor",
    })
    const [child] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Private Child",
        spaceId: space.id,
        publicThread: false,
        parentChatId: privateThreadId,
        parentMessageId: 1,
      })
      .returning()
    if (!child) throw new Error("Child chat not created")
    await db.insert(schema.chatParticipants).values({ chatId: child.id, userId: memberUser.id })
    const [group] = await db
      .insert(schema.userGroups)
      .values({ spaceId: space.id, name: "Private child access", createdBy: adminUser.id })
      .returning()
    if (!group) throw new Error("Child access group not created")
    await db.insert(schema.userGroupMembers).values({ groupId: group.id, userId: memberUser.id })
    await db.insert(schema.chatParticipantGroups).values({ chatId: child.id, groupId: group.id })

    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
      handlerContext,
    )

    const remainingGrants = await db
      .select({ chatId: schema.chatParticipants.chatId })
      .from(schema.chatParticipants)
      .where(eq(schema.chatParticipants.userId, memberUser.id))
    expect(remainingGrants).toEqual([])
    const remainingGroupMemberships = await db
      .select({ groupId: schema.userGroupMembers.groupId })
      .from(schema.userGroupMembers)
      .where(eq(schema.userGroupMembers.userId, memberUser.id))
    expect(remainingGroupMemberships).toEqual([])

    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, memberUser.id)))
      .orderBy(schema.updates.seq)
    const removedChatIds = userUpdates.flatMap((row) => {
      const payload = UpdatesModel.decrypt(row).payload.update
      return payload.oneofKind === "userRemovedFromChat"
        ? [Number(payload.userRemovedFromChat.chatId)]
        : []
    })
    expect(removedChatIds).toEqual([privateThreadId])
    expect(removedChatIds).not.toContain(child.id)
  })

  test("serializes member deletion with a concurrent public-space join", async () => {
    const handle = `delete-member-race-${space.id}`
    await db
      .update(schema.spaces)
      .set({ handle, isPublic: true, canPublicJoin: true })
      .where(eq(schema.spaces.id, space.id))

    const [deletion, join] = await Promise.allSettled([
      deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
        handlerContext,
      ),
      joinPublicSpace(
        { handle },
        { currentUserId: memberUser.id, currentSessionId: 1 },
      ),
    ])

    expect(deletion.status).toBe("fulfilled")
    if (deletion.status !== "fulfilled") throw deletion.reason
    expect(deletion.value.updates.length).toBeGreaterThan(0)
    if (join.status === "fulfilled") {
      expect(join.value.alreadyMember).toBe(true)
    } else {
      expect(join.reason).toMatchObject({ codeName: "SPACE_INVITE_INVALID" })
    }
    const remainingMembers = await db
      .select()
      .from(schema.members)
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, memberUser.id)))
    expect(remainingMembers).toHaveLength(0)
    expect(await db
      .select()
      .from(schema.spaceJoinBlocks)
      .where(and(
        eq(schema.spaceJoinBlocks.spaceId, space.id),
        eq(schema.spaceJoinBlocks.userId, memberUser.id),
      ))).toHaveLength(1)
  })

  test("revokes active Grid presence and reconciles the remaining room", async () => {
    const adminSession = await testUtils.createSessionForUser(adminUser.id)
    const memberSession = await testUtils.createSessionForUser(memberUser.id)
    const adminContext = testUtils.functionContext({
      userId: adminUser.id,
      sessionId: adminSession.session.id,
    })
    const memberContext = testUtils.functionContext({
      userId: memberUser.id,
      sessionId: memberSession.session.id,
    })
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, adminContext)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, adminContext)
    const roomID = created.grids[0]!.rooms[0]!.id
    await joinGridRoom({ roomId: roomID }, memberContext)

    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
      handlerContext,
    )

    const presence = await db
      .select()
      .from(schema.gridPresence)
      .where(eq(schema.gridPresence.userId, memberUser.id))
    expect(presence).toEqual([])
    const revocations = await db
      .select()
      .from(schema.gridProviderEffects)
      .where(
        and(
          eq(schema.gridProviderEffects.kind, "revoke_participant"),
          eq(schema.gridProviderEffects.userId, memberUser.id),
        ),
      )
    expect(revocations).toHaveLength(1)
    const grid = await getGrid({ spaceId: BigInt(space.id) }, adminContext)
    expect(grid.grid?.rooms[0]?.avatars.map((avatar) => avatar.user?.id)).toEqual([BigInt(adminUser.id)])
    expect(grid.grid?.rooms[0]?.connection).toBeUndefined()
  })

  test("rolls Grid presence and provider revocation back when member deletion fails", async () => {
    const adminSession = await testUtils.createSessionForUser(adminUser.id)
    const memberSession = await testUtils.createSessionForUser(memberUser.id)
    const adminContext = testUtils.functionContext({
      userId: adminUser.id,
      sessionId: adminSession.session.id,
    })
    const memberContext = testUtils.functionContext({
      userId: memberUser.id,
      sessionId: memberSession.session.id,
    })
    await toggleSpaceGrid({ spaceId: BigInt(space.id), enabled: true }, adminContext)
    const created = await createGridRoom({ spaceId: BigInt(space.id) }, adminContext)
    await joinGridRoom({ roomId: created.grids[0]!.rooms[0]!.id }, memberContext)

    // Model an inconsistent pre-existing row so the handler reaches the Grid
    // cleanup and then discovers that the membership no longer exists.
    await db
      .delete(schema.members)
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, memberUser.id)))

    await expect(
      deleteMemberHandler(
        { spaceId: BigInt(space.id), userId: BigInt(memberUser.id), blockJoin: false },
        handlerContext,
      ),
    ).rejects.toThrow()

    const presence = await db
      .select()
      .from(schema.gridPresence)
      .where(eq(schema.gridPresence.userId, memberUser.id))
    expect(presence).toHaveLength(1)
    const revocations = await db
      .select()
      .from(schema.gridProviderEffects)
      .where(eq(schema.gridProviderEffects.userId, memberUser.id))
    expect(revocations).toEqual([])
  })
})
