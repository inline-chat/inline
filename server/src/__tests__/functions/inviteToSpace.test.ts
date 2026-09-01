import { describe, test, expect, spyOn } from "bun:test"
import { inviteToSpace } from "@in/server/functions/space.inviteToSpace"
import { testUtils, setupTestLifecycle } from "../setup"
import { InviteToSpaceInput, Member_Role } from "@inline-chat/protocol/core"
import { schema } from "@in/server/db/relations"
import { db } from "@in/server/db"
import { and, asc, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"

function makeFunctionContext(userId: number) {
  return {
    currentUserId: userId,
    currentSessionId: 1,
  }
}

describe("inviteToSpace", () => {
  setupTestLifecycle()

  test("successfully invites a user by email", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Invite Space", ["owner@ex.com"])
    const owner = users[0]
    // Update permission to admin
    await db.update(schema.members).set({ role: "admin" }).where(and(eq(schema.members.userId, owner.id), eq(schema.members.spaceId, space.id))).execute()
    
    const input: InviteToSpaceInput = {
      spaceId: BigInt(space.id),
      role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
      via: { oneofKind: "email" as const, email: "invitee@ex.com" },
    }
    const context = makeFunctionContext(owner.id)
    const result = await inviteToSpace(input, context)
    expect(result.user).toBeTruthy()
    expect(result.member).toBeTruthy()

    if (result.user && result.member) {
      expect(result.user.email).toBe("invitee@ex.com")
      expect(result.member.spaceId).toBe(BigInt(space.id))
    }
    // Chat & dialog are no longer created as part of invite flow
    expect(result.chat).toBeUndefined()
    expect(result.dialog).toBeUndefined()
  })

  test("allows owners to invite a user by email", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Owner Invite Space", ["owner-invite@ex.com"])
    const owner = users[0]

    await db
      .update(schema.members)
      .set({ role: "owner" })
      .where(and(eq(schema.members.userId, owner.id), eq(schema.members.spaceId, space.id)))
      .execute()

    const input: InviteToSpaceInput = {
      spaceId: BigInt(space.id),
      role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
      via: { oneofKind: "email" as const, email: "owner-invitee@ex.com" },
    }

    const result = await inviteToSpace(input, makeFunctionContext(owner.id))

    expect(result.user?.email).toBe("owner-invitee@ex.com")
    expect(result.member?.spaceId).toBe(BigInt(space.id))
    expect(result.member?.role).toBe(Member_Role.MEMBER)
  })

  test("opens the primary chat for an invited member", async () => {
    const owner = await testUtils.createUser("primary-chat-inviter@ex.com")
    const invitee = await testUtils.createUser("primary-chat-invitee@ex.com")
    const created = await createSpace(
      { name: "Invited Town Hall" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )

    const [primaryChat] = await db
      .select()
      .from(schema.chats)
      .where(and(eq(schema.chats.spaceId, created.space.id), eq(schema.chats.threadNumber, 1)))
      .limit(1)
    expect(primaryChat).toBeTruthy()
    if (!primaryChat) throw new Error("Expected primary chat")
    const [childChat] = await db
      .insert(schema.chats)
      .values({
        spaceId: created.space.id,
        type: "thread",
        title: "Announcements",
        publicThread: true,
        parentChatId: primaryChat.id,
        threadNumber: 2,
      })
      .returning()
    if (!childChat) throw new Error("Expected descendant chat")
    await db.insert(schema.acknowledgements).values({
      chatId: primaryChat.id,
      userId: owner.id,
      maxId: 42,
      revision: 7,
      cleared: false,
    })

    await inviteToSpace(
      {
        spaceId: BigInt(created.space.id),
        role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
        via: { oneofKind: "userId", userId: BigInt(invitee.id) },
      },
      makeFunctionContext(owner.id),
    )

    const [dialog] = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, primaryChat.id), eq(schema.dialogs.userId, invitee.id)))
      .limit(1)
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBeString()

    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitee.id)))
    const decodedUpdates = userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update)
    expect(decodedUpdates.map((update) => update.oneofKind)).toEqual([
      "userJoinSpace",
      "userAddedToChat",
      "userChatOpen",
    ])
    expect(
      decodedUpdates
        .filter((update) => update.oneofKind === "userAddedToChat")
        .map((update) => update.userAddedToChat.chatId),
    ).toEqual([BigInt(primaryChat.id)])
    expect(
      decodedUpdates
        .filter((update) => update.oneofKind === "userAddedToChat")
        .map((update) => update.userAddedToChat.chatId),
    ).not.toContain(BigInt(childChat.id))
    const chatOpen = decodedUpdates.find((update) => update.oneofKind === "userChatOpen")
    expect(
      chatOpen?.oneofKind === "userChatOpen"
        ? chatOpen.userChatOpen.chat?.acknowledgements?.cursors.map((cursor) => ({
            userId: cursor.userId,
            maxId: cursor.maxId,
            revision: cursor.revision,
          }))
        : undefined,
    ).toEqual([{ userId: BigInt(owner.id), maxId: 42n, revision: 7n }])
  })

  test("commits membership and contiguous space/user updates as one durable invite", async () => {
    const owner = await testUtils.createUser("atomic-inviter@ex.com")
    const invitee = await testUtils.createUser("atomic-invitee@ex.com")
    const created = await createSpace(
      { name: "Atomic Invite Space" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )

    await inviteToSpace(
      {
        spaceId: BigInt(created.space.id),
        role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
        via: { oneofKind: "userId", userId: BigInt(invitee.id) },
      },
      makeFunctionContext(owner.id),
    )

    const [membership] = await db
      .select()
      .from(schema.members)
      .where(and(eq(schema.members.spaceId, created.space.id), eq(schema.members.userId, invitee.id)))
      .limit(1)
    expect(membership).toBeTruthy()

    const spaceUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, created.space.id)))
      .orderBy(asc(schema.updates.seq))
    expect(spaceUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
      "spaceMemberAdd",
    ])

    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitee.id)))
      .orderBy(asc(schema.updates.seq))
    expect(userUpdates.map((row) => row.seq)).toEqual(userUpdates.map((_, index) => index + 1))
    expect(userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
      "userJoinSpace",
      "userAddedToChat",
      "userChatOpen",
    ])

    const [persistedUser] = await db.select().from(schema.users).where(eq(schema.users.id, invitee.id)).limit(1)
    expect(persistedUser?.updateSeq).toBe(userUpdates.at(-1)?.seq)
  })

  test("hydrates acknowledgement snapshots without requiring a second pool connection", async () => {
    const owner = await testUtils.createUser("pool-bound-inviter@ex.com")
    const created = await createSpace(
      { name: "Pool Bound Invite Space" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )
    const [primaryChat] = await db
      .select()
      .from(schema.chats)
      .where(and(eq(schema.chats.spaceId, created.space.id), eq(schema.chats.threadNumber, 1)))
      .limit(1)
    if (!primaryChat) throw new Error("Expected primary chat")
    await db.insert(schema.acknowledgements).values({
      chatId: primaryChat.id,
      userId: owner.id,
      maxId: 11,
      revision: 3,
      cleared: false,
    })
    const invitees = await db
      .insert(schema.users)
      .values(Array.from({ length: 12 }, () => ({ pendingSetup: true })))
      .returning()

    await Promise.all(
      invitees.map((invitee) =>
        inviteToSpace(
          {
            spaceId: BigInt(created.space.id),
            role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
            via: { oneofKind: "userId", userId: BigInt(invitee.id) },
          },
          makeFunctionContext(owner.id),
        ),
      ),
    )

    expect(await db.select().from(schema.members).where(eq(schema.members.spaceId, created.space.id))).toHaveLength(
      invitees.length + 1,
    )
    const firstInviteeUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitees[0]!.id)))
      .orderBy(asc(schema.updates.seq))
    const chatOpen = firstInviteeUpdates
      .map((row) => UpdatesModel.decrypt(row).payload.update)
      .find((update) => update.oneofKind === "userChatOpen")
    expect(
      chatOpen?.oneofKind === "userChatOpen" ? chatOpen.userChatOpen.chat?.id : undefined,
    ).toBe(BigInt(primaryChat.id))
    expect(
      chatOpen?.oneofKind === "userChatOpen"
        ? chatOpen.userChatOpen.chat?.acknowledgements?.cursors.map((cursor) => cursor.maxId)
        : undefined,
    ).toEqual([11n])
  })

  test("rejects a soft-deleted space under the mutation lock without durable invite rows", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Soft Deleted Invite Space", [
      "soft-deleted-inviter@ex.com",
    ])
    const inviter = users[0]
    const inviteeEmail = "soft-deleted-invitee@ex.com"
    await db
      .update(schema.members)
      .set({ role: "owner" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, inviter.id)))
    await db.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, space.id))

    await expect(
      inviteToSpace(
        {
          spaceId: BigInt(space.id),
          role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
          via: { oneofKind: "email", email: inviteeEmail },
        },
        makeFunctionContext(inviter.id),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ID_INVALID })

    expect(await db.select().from(schema.users).where(eq(schema.users.email, inviteeEmail))).toHaveLength(0)
    expect(await db.select().from(schema.members).where(eq(schema.members.spaceId, space.id))).toHaveLength(1)
    expect(
      await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, space.id))),
    ).toHaveLength(0)
  })

  test("rolls back a newly created pending identity when invite persistence fails", async () => {
    const owner = await testUtils.createUser("pending-rollback-inviter@ex.com")
    const created = await createSpace(
      { name: "Pending Identity Rollback Space" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )
    const inviteeEmail = "pending-rollback-invitee@ex.com"
    const originalEnqueue = UserBucketUpdates.enqueue
    let enqueueCallCount = 0
    const enqueue = spyOn(UserBucketUpdates, "enqueue").mockImplementation(async (enqueueInput, options) => {
      enqueueCallCount += 1
      if (enqueueCallCount === 2) {
        throw new Error("injected pending identity persistence failure")
      }
      return originalEnqueue(enqueueInput, options)
    })

    const input: InviteToSpaceInput = {
      spaceId: BigInt(created.space.id),
      role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
      via: { oneofKind: "email", email: inviteeEmail },
    }
    try {
      await expect(inviteToSpace(input, makeFunctionContext(owner.id))).rejects.toThrow(
        "injected pending identity persistence failure",
      )
    } finally {
      enqueue.mockRestore()
    }

    expect(await db.select().from(schema.users).where(eq(schema.users.email, inviteeEmail))).toHaveLength(0)
    expect(await db.select().from(schema.members).where(eq(schema.members.spaceId, created.space.id))).toHaveLength(1)
    expect(
      await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, created.space.id))),
    ).toHaveLength(0)

    await expect(inviteToSpace(input, makeFunctionContext(owner.id))).resolves.toBeTruthy()
    expect(await db.select().from(schema.users).where(eq(schema.users.email, inviteeEmail))).toHaveLength(1)
  })

  test("does not ghost-reopen the primary dialog when removal starts during post-commit fanout", async () => {
    const owner = await testUtils.createUser("fanout-race-inviter@ex.com")
    const invitee = await testUtils.createUser("fanout-race-invitee@ex.com")
    const created = await createSpace(
      { name: "Fanout Race Space" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )

    let removal: ReturnType<typeof deleteMemberHandler> | undefined
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (userId, updates) => {
      if (
        userId === invitee.id &&
        removal === undefined &&
        updates.some((update) => update.update.oneofKind === "joinSpace")
      ) {
        removal = deleteMemberHandler(
          { spaceId: BigInt(created.space.id), userId: BigInt(invitee.id), blockJoin: false },
          {
            userId: owner.id,
            sessionId: 1,
            connectionId: "invite-delete-race",
            sendRaw: () => {},
            sendRpcReply: () => {},
          },
        )
      }
    })

    try {
      await inviteToSpace(
        {
          spaceId: BigInt(created.space.id),
          role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
          via: { oneofKind: "userId", userId: BigInt(invitee.id) },
        },
        makeFunctionContext(owner.id),
      )
      expect(removal).toBeDefined()
      await removal
    } finally {
      push.mockRestore()
    }

    expect(
      await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.spaceId, created.space.id), eq(schema.members.userId, invitee.id))),
    ).toHaveLength(0)
    expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, invitee.id))).toHaveLength(0)

    const durableKinds = (
      await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitee.id)))
        .orderBy(asc(schema.updates.seq))
    ).map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)
    expect(durableKinds).toContain("userChatOpen")
    expect(durableKinds.at(-1)).not.toBe("userChatOpen")
  })

  test("does not fail a committed invite when the internal alert rejects", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Alert Failure Invite Space", [
      "alert-failure-inviter@ex.com",
    ])
    const inviter = users[0]
    const invitee = await testUtils.createUser("alert-failure-invitee@ex.com")
    await db
      .update(schema.members)
      .set({ role: "owner" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, inviter.id)))

    const alert = spyOn(BotAlerts, "spaceInvite").mockRejectedValueOnce(new Error("injected bot alert failure"))
    try {
      await expect(
        inviteToSpace(
          {
            spaceId: BigInt(space.id),
            role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
            via: { oneofKind: "userId", userId: BigInt(invitee.id) },
          },
          makeFunctionContext(inviter.id),
        ),
      ).resolves.toBeTruthy()
    } finally {
      alert.mockRestore()
    }

    expect(
      await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, invitee.id))),
    ).toHaveLength(1)
  })

  test("rechecks inviter authority after target resolution and leaves no invite rows when revoked", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Revoked Invite Space", [
      "revoked-inviter@ex.com",
    ])
    const inviter = users[0]
    const invitee = await testUtils.createUser("revoked-race-invitee@ex.com")
    await db
      .update(schema.members)
      .set({ role: "owner" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, inviter.id)))

    const spaceUpdateCountBefore = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, space.id)))
    const userUpdateCountBefore = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitee.id)))

    let attempt!: ReturnType<typeof inviteToSpace>
    await db.transaction(async (tx) => {
      await tx
        .select({ id: schema.users.id })
        .from(schema.users)
        .where(eq(schema.users.id, invitee.id))
        .for("update")
        .limit(1)

      // The canonical mutation must acquire this target owner before reading
      // actor authority. Revoke authority while it is blocked there; once this
      // transaction commits it must observe the missing actor membership.
      attempt = inviteToSpace(
        {
          spaceId: BigInt(space.id),
          role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
          via: { oneofKind: "userId", userId: BigInt(invitee.id) },
        },
        makeFunctionContext(inviter.id),
      )

      await db
        .delete(schema.members)
        .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, inviter.id)))
    })

    await expect(attempt).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })
    expect(
      await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, invitee.id))),
    ).toHaveLength(0)
    expect(
      await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, space.id))),
    ).toHaveLength(spaceUpdateCountBefore.length)
    expect(
      await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitee.id))),
    ).toHaveLength(userUpdateCountBefore.length)
  })

  test("rolls back membership and all bucket rows when durable invite persistence fails", async () => {
    const inviter = await testUtils.createUser("rollback-inviter@ex.com")
    const invitee = await testUtils.createUser("rollback-invitee@ex.com")
    const created = await createSpace(
      { name: "Rollback Invite Space" },
      { currentUserId: inviter.id, currentSessionId: 1, ip: undefined },
    )
    const spaceId = created.space.id

    const [spaceBefore] = await db.select().from(schema.spaces).where(eq(schema.spaces.id, spaceId)).limit(1)
    const [userBefore] = await db.select().from(schema.users).where(eq(schema.users.id, invitee.id)).limit(1)
    const originalEnqueue = UserBucketUpdates.enqueue
    let enqueueCallCount = 0
    const enqueue = spyOn(UserBucketUpdates, "enqueue").mockImplementation(async (enqueueInput, options) => {
      enqueueCallCount += 1
      if (enqueueCallCount === 2) {
        throw new Error("injected invite persistence failure")
      }
      return originalEnqueue(enqueueInput, options)
    })

    const input: InviteToSpaceInput = {
      spaceId: BigInt(spaceId),
      role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
      via: { oneofKind: "userId", userId: BigInt(invitee.id) },
    }
    try {
      await expect(inviteToSpace(input, makeFunctionContext(inviter.id))).rejects.toThrow(
        "injected invite persistence failure",
      )
    } finally {
      enqueue.mockRestore()
    }

    expect(
      await db
        .select()
        .from(schema.members)
        .where(and(eq(schema.members.spaceId, spaceId), eq(schema.members.userId, invitee.id))),
    ).toHaveLength(0)
    expect(
      await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, UpdateBucket.Space), eq(schema.updates.entityId, spaceId))),
    ).toHaveLength(0)
    expect(
      await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitee.id))),
    ).toHaveLength(0)

    expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, invitee.id))).toHaveLength(0)

    const [spaceAfter] = await db.select().from(schema.spaces).where(eq(schema.spaces.id, spaceId)).limit(1)
    const [userAfter] = await db.select().from(schema.users).where(eq(schema.users.id, invitee.id)).limit(1)
    expect(spaceAfter?.updateSeq).toBe(spaceBefore?.updateSeq)
    expect(userAfter?.updateSeq).toBe(userBefore?.updateSeq)

    await expect(inviteToSpace(input, makeFunctionContext(inviter.id))).resolves.toBeTruthy()
  })

  test("does not open the public primary chat for a restricted member", async () => {
    const owner = await testUtils.createUser("restricted-primary-inviter@ex.com")
    const invitee = await testUtils.createUser("restricted-primary-invitee@ex.com")
    const created = await createSpace(
      { name: "Restricted Town Hall" },
      { currentUserId: owner.id, currentSessionId: 1, ip: undefined },
    )

    await inviteToSpace(
      {
        spaceId: BigInt(created.space.id),
        role: { role: { oneofKind: "member", member: { canAccessPublicChats: false } } },
        via: { oneofKind: "userId", userId: BigInt(invitee.id) },
      },
      makeFunctionContext(owner.id),
    )

    expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, invitee.id))).toHaveLength(0)
    const userUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, invitee.id)))
    expect(userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual(["userJoinSpace"])
  })

  test("allows public space members to invite regular members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Member Invite Space", ["public-member@ex.com"])
    const member = users[0]
    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, space.id)).execute()

    const input: InviteToSpaceInput = {
      spaceId: BigInt(space.id),
      via: { oneofKind: "email" as const, email: "public-invitee@ex.com" },
    }

    const result = await inviteToSpace(input, makeFunctionContext(member.id))

    expect(result.user?.email).toBe("public-invitee@ex.com")
    expect(result.member?.spaceId).toBe(BigInt(space.id))
    expect(result.member?.role).toBe(Member_Role.MEMBER)
  })

  test("throws error for invalid spaceId", async () => {
    const input: InviteToSpaceInput = {
      spaceId: BigInt(-1),
      role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
      via: { oneofKind: "email" as const, email: "invitee@ex.com" },
    }
    const context = makeFunctionContext(1)
    await expect(inviteToSpace(input, context)).rejects.toThrow()
  })

  test("throws error when member tries to invite as admin", async () => {
    // Create space with a member (not owner)
    const { space, users } = await testUtils.createSpaceWithMembers("Member Space", ["member@ex.com"])
    const member = users[0]
    // Manually set role to 'member' if needed (depends on implementation)
    const input = {
      spaceId: BigInt(space.id),
      role: { role: { oneofKind: "admin" as const, admin: {} } },
      via: { oneofKind: "email" as const, email: "invitee2@ex.com" },
    }
    const context = makeFunctionContext(member.id)
    await expect(inviteToSpace(input, context)).rejects.toThrow()
  })

  test("throws error when private space member tries to invite without role", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Member Default Role Space", ["member-default@ex.com"])
    const member = users[0]

    const input: InviteToSpaceInput = {
      spaceId: BigInt(space.id),
      via: { oneofKind: "email" as const, email: "invitee-default@ex.com" },
    }

    await expect(inviteToSpace(input, makeFunctionContext(member.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED,
    })
  })

  test("throws error when public space member tries to invite as admin", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Member Admin Invite Space", ["public-admin-member@ex.com"])
    const member = users[0]
    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, space.id)).execute()

    const input: InviteToSpaceInput = {
      spaceId: BigInt(space.id),
      role: { role: { oneofKind: "admin", admin: {} } },
      via: { oneofKind: "email" as const, email: "public-admin-invitee@ex.com" },
    }

    await expect(inviteToSpace(input, makeFunctionContext(member.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED,
    })
  })

  test("rejects inviting a deleted user by id", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Deleted Invite Space", ["deleted-inviter@ex.com"])
    const inviter = users[0]
    await db
      .update(schema.members)
      .set({ role: "admin" })
      .where(and(eq(schema.members.userId, inviter.id), eq(schema.members.spaceId, space.id)))
      .execute()

    const deletedUser = await testUtils.createUser("deleted-invitee@ex.com")
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, deletedUser.id)).execute()

    const input: InviteToSpaceInput = {
      spaceId: BigInt(space.id),
      role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
      via: { oneofKind: "userId", userId: BigInt(deletedUser.id) },
    }

    await expect(inviteToSpace(input, makeFunctionContext(inviter.id))).rejects.toThrow()
  })
})
