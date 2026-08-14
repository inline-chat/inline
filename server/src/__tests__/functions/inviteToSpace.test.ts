import { describe, test, expect } from "bun:test"
import { inviteToSpace } from "@in/server/functions/space.inviteToSpace"
import { testUtils, setupTestLifecycle } from "../setup"
import { InviteToSpaceInput, Member_Role } from "@inline-chat/protocol/core"
import { schema } from "@in/server/db/relations"
import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema"

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

    await inviteToSpace(
      {
        spaceId: BigInt(created.space.id),
        role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
        via: { oneofKind: "userId", userId: BigInt(invitee.id) },
      },
      makeFunctionContext(owner.id),
    )

    const [primaryChat] = await db
      .select()
      .from(schema.chats)
      .where(and(eq(schema.chats.spaceId, created.space.id), eq(schema.chats.threadNumber, 1)))
      .limit(1)
    expect(primaryChat).toBeTruthy()
    if (!primaryChat) throw new Error("Expected primary chat")

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
    expect(userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual([
      "userJoinSpace",
      "userChatOpen",
    ])
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
