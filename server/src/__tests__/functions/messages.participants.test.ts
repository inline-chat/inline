import { describe, expect, test } from "bun:test"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { removeChatParticipant } from "@in/server/functions/messages.removeChatParticipant"
import { getChatParticipants } from "@in/server/functions/messages.getChatParticipants"
import { createUserGroup, deleteUserGroup, getUserGroups, updateUserGroup } from "@in/server/modules/userGroups"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"

const makeFunctionContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
})

const addSpaceMembers = async (
  spaceId: number,
  rows: { userId: number; role?: "owner" | "admin" | "member"; canAccessPublicChats?: boolean }[],
) => {
  await db.insert(schema.members).values(
    rows.map((row) => ({
      spaceId,
      userId: row.userId,
      role: row.role ?? "member",
      canAccessPublicChats: row.canAccessPublicChats ?? true,
    })),
  )
}

describe("home thread participant management", () => {
  setupTestLifecycle()

  test("rejects participant changes for non-thread chats", async () => {
    const userA = await testUtils.createUser("non-thread-owner@example.com")
    const userB = await testUtils.createUser("non-thread-target@example.com")
    if (!userA || !userB) throw new Error("Users not created")

    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Chat not created")

    await expect(
      addChatParticipant({ chatId: chat.id, userId: userB.id }, makeFunctionContext(userA.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })

    await expect(
      removeChatParticipant({ chatId: chat.id, userId: userB.id }, makeFunctionContext(userA.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("only creator can add participants to home thread", async () => {
    const creator = await testUtils.createUser("home-add-creator@example.com")
    const target = await testUtils.createUser("home-add-target@example.com")
    const outsider = await testUtils.createUser("home-add-outsider@example.com")
    if (!creator || !target || !outsider) throw new Error("Users not created")

    const chat = await testUtils.createChat(null, "Home Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")

    await testUtils.addParticipant(chat.id, creator.id)

    const added = await addChatParticipant(
      { chatId: chat.id, userId: target.id },
      makeFunctionContext(creator.id),
    )

    expect(Number(added.participant?.userId)).toBe(target.id)

    const participant = await db
      .select()
      .from(schema.chatParticipants)
      .where(and(eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, target.id)))
      .then((rows) => rows[0])

    expect(participant).toBeDefined()

    await expect(
      addChatParticipant({ chatId: chat.id, userId: outsider.id }, makeFunctionContext(target.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
  })

  test("rejects adding deleted users to a home thread", async () => {
    const creator = await testUtils.createUser("home-add-deleted-creator@example.com")
    const target = await testUtils.createUser("home-add-deleted-target@example.com")
    if (!creator || !target) throw new Error("Users not created")

    const chat = await testUtils.createChat(null, "Home Deleted Target", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")

    await testUtils.addParticipant(chat.id, creator.id)
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, target.id))

    await expect(
      addChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(creator.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("only creator can remove participants from home thread", async () => {
    const creator = await testUtils.createUser("home-remove-creator@example.com")
    const participant = await testUtils.createUser("home-remove-participant@example.com")
    const outsider = await testUtils.createUser("home-remove-outsider@example.com")
    if (!creator || !participant || !outsider) throw new Error("Users not created")

    const chat = await testUtils.createChat(null, "Home Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")

    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, participant.id)

    await expect(
      removeChatParticipant({ chatId: chat.id, userId: participant.id }, makeFunctionContext(outsider.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })

    await removeChatParticipant({ chatId: chat.id, userId: participant.id }, makeFunctionContext(creator.id))

    const remaining = await db
      .select()
      .from(schema.chatParticipants)
      .where(and(eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, participant.id)))

    expect(remaining.length).toBe(0)
  })
})

describe("space thread participant management", () => {
  setupTestLifecycle()

  test("requires creator or space admin to add participants", async () => {
    const space = await testUtils.createSpace("participant-auth-space")
    const creator = await testUtils.createUser("space-participant-creator@example.com")
    const admin = await testUtils.createUser("space-participant-admin@example.com")
    const member = await testUtils.createUser("space-participant-member@example.com")
    const target = await testUtils.createUser("space-participant-target@example.com")
    if (!space || !creator || !admin || !member || !target) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [
      { userId: creator.id },
      { userId: admin.id, role: "admin" },
      { userId: member.id },
      { userId: target.id },
    ])

    const chat = await testUtils.createChat(space.id, "Private Space Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, creator.id)

    await expect(
      addChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(member.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })

    const added = await addChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(admin.id))
    expect(Number(added.participant?.userId)).toBe(target.id)
  })

  test("rejects adding users who are not members of the space", async () => {
    const space = await testUtils.createSpace("participant-target-space")
    const creator = await testUtils.createUser("space-target-creator@example.com")
    const outsider = await testUtils.createUser("space-target-outsider@example.com")
    if (!space || !creator || !outsider) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [{ userId: creator.id, role: "owner" }])

    const chat = await testUtils.createChat(space.id, "Private Space Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, creator.id)

    await expect(
      addChatParticipant({ chatId: chat.id, userId: outsider.id }, makeFunctionContext(creator.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.USER_ID_INVALID })
  })

  test("adds and removes group participants for private space threads", async () => {
    const space = await testUtils.createSpace("participant-group-space")
    const creator = await testUtils.createUser("space-group-creator@example.com")
    const member = await testUtils.createUser("space-group-member@example.com")
    const outsider = await testUtils.createUser("space-group-outsider@example.com")
    if (!space || !creator || !member || !outsider) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [
      { userId: creator.id, role: "owner" },
      { userId: member.id },
      { userId: outsider.id },
    ])

    const createdGroup = await createUserGroup(
      {
        spaceId: space.id,
        name: "Eng",
        description: "Engineering reviewers",
        userIds: [member.id],
      },
      makeFunctionContext(creator.id),
    )
    const groupId = Number(createdGroup.group.id)

    const chat = await testUtils.createChat(space.id, "Private Group Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, creator.id)

    await expect(AccessGuards.ensureChatAccess(chat, member.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })

    const added = await addChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(creator.id))
    expect(Number(added.groupParticipant?.groupId)).toBe(groupId)
    expect(added.group?.name).toBe("Eng")

    await expect(AccessGuards.ensureChatAccess(chat, member.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(chat, outsider.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })

    const participants = await getChatParticipants({ chatId: chat.id }, makeFunctionContext(creator.id))
    expect(participants.groupParticipants.map((group) => Number(group.groupId))).toContain(groupId)
    expect(participants.groups.map((group) => group.name)).toContain("Eng")

    await removeChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(creator.id))
    await expect(AccessGuards.ensureChatAccess(chat, member.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })
  })

  test("blocks deleting groups that are used by threads", async () => {
    const space = await testUtils.createSpace("participant-group-delete-space")
    const creator = await testUtils.createUser("space-group-delete-creator@example.com")
    const member = await testUtils.createUser("space-group-delete-member@example.com")
    if (!space || !creator || !member) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [
      { userId: creator.id, role: "owner" },
      { userId: member.id },
    ])

    const createdGroup = await createUserGroup(
      {
        spaceId: space.id,
        name: "Design",
        userIds: [member.id],
      },
      makeFunctionContext(creator.id),
    )
    const groupId = Number(createdGroup.group.id)

    const chat = await testUtils.createChat(space.id, "Private Group Delete Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, creator.id)
    await addChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(creator.id))

    await expect(deleteUserGroup({ groupId }, makeFunctionContext(creator.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })

    await removeChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(creator.id))
    await expect(deleteUserGroup({ groupId }, makeFunctionContext(creator.id))).resolves.toBeUndefined()
  })

  test("updates group-granted thread access when group members change", async () => {
    const space = await testUtils.createSpace("participant-group-update-space")
    const creator = await testUtils.createUser("space-group-update-creator@example.com")
    const oldMember = await testUtils.createUser("space-group-update-old@example.com")
    const newMember = await testUtils.createUser("space-group-update-new@example.com")
    if (!space || !creator || !oldMember || !newMember) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [
      { userId: creator.id, role: "owner" },
      { userId: oldMember.id },
      { userId: newMember.id },
    ])

    const createdGroup = await createUserGroup(
      {
        spaceId: space.id,
        name: "Support",
        userIds: [oldMember.id],
      },
      makeFunctionContext(creator.id),
    )
    const groupId = Number(createdGroup.group.id)

    const chat = await testUtils.createChat(space.id, "Private Group Update Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, creator.id)
    await addChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(creator.id))

    await expect(AccessGuards.ensureChatAccess(chat, oldMember.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(chat, newMember.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })

    await updateUserGroup(
      {
        groupId,
        name: "Support",
        userIds: [newMember.id],
      },
      makeFunctionContext(creator.id),
    )

    await expect(AccessGuards.ensureChatAccess(chat, oldMember.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })
    await expect(AccessGuards.ensureChatAccess(chat, newMember.id)).resolves.toBeUndefined()
  })

  test("allows empty groups to remain visible in private spaces", async () => {
    const space = await testUtils.createSpace("participant-empty-group-space")
    const owner = await testUtils.createUser("empty-group-owner@example.com")
    if (!space || !owner) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [{ userId: owner.id, role: "owner" }])

    const created = await createUserGroup(
      {
        spaceId: space.id,
        name: "Empty",
        userIds: [],
      },
      makeFunctionContext(owner.id),
    )
    expect(created.group.memberCount).toBe(0)
    expect(created.group.userIds).toEqual([])

    const listed = await getUserGroups({ spaceId: space.id }, makeFunctionContext(owner.id))
    expect(listed.groups.map((group) => group.name)).toContain("Empty")
    expect(listed.users).toEqual([])
  })

  test("rejects invalid group member ids", async () => {
    const space = await testUtils.createSpace("participant-invalid-group-member-space")
    const owner = await testUtils.createUser("invalid-group-member-owner@example.com")
    if (!space || !owner) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [{ userId: owner.id, role: "owner" }])

    await expect(
      createUserGroup(
        {
          spaceId: space.id,
          name: "Invalid",
          userIds: [owner.id, -1],
        },
        makeFunctionContext(owner.id),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.USER_ID_INVALID })
  })

  test("only lists groups regular members belong to in public spaces", async () => {
    const space = await testUtils.createSpace("participant-public-group-space")
    const owner = await testUtils.createUser("public-group-owner@example.com")
    const memberA = await testUtils.createUser("public-group-a@example.com")
    const memberB = await testUtils.createUser("public-group-b@example.com")
    if (!space || !owner || !memberA || !memberB) throw new Error("Failed to create test data")

    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, space.id))
    await addSpaceMembers(space.id, [
      { userId: owner.id, role: "owner" },
      { userId: memberA.id },
      { userId: memberB.id },
    ])

    await createUserGroup(
      {
        spaceId: space.id,
        name: "Alpha",
        userIds: [memberA.id],
      },
      makeFunctionContext(owner.id),
    )
    await createUserGroup(
      {
        spaceId: space.id,
        name: "Beta",
        userIds: [memberB.id],
      },
      makeFunctionContext(owner.id),
    )

    const result = await getUserGroups({ spaceId: space.id }, makeFunctionContext(memberA.id))
    expect(result.groups.map((group) => group.name)).toEqual(["Alpha"])
    expect(result.users.map((user) => Number(user.id))).toEqual([memberA.id])

    const ownerResult = await getUserGroups({ spaceId: space.id }, makeFunctionContext(owner.id))
    expect(ownerResult.groups.map((group) => group.name)).toEqual(["Alpha", "Beta"])
    expect(ownerResult.users.map((user) => Number(user.id)).sort((a, b) => a - b)).toEqual(
      [memberA.id, memberB.id].sort((a, b) => a - b),
    )
  })

  test("requires creator or space admin to remove participants", async () => {
    const space = await testUtils.createSpace("participant-remove-space")
    const creator = await testUtils.createUser("space-remove-creator@example.com")
    const admin = await testUtils.createUser("space-remove-admin@example.com")
    const member = await testUtils.createUser("space-remove-member@example.com")
    const target = await testUtils.createUser("space-remove-target@example.com")
    if (!space || !creator || !admin || !member || !target) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [
      { userId: creator.id },
      { userId: admin.id, role: "admin" },
      { userId: member.id },
      { userId: target.id },
    ])

    const chat = await testUtils.createChat(space.id, "Private Space Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, target.id)

    await expect(
      removeChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(member.id)),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED })

    await removeChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(admin.id))

    const remaining = await db
      .select()
      .from(schema.chatParticipants)
      .where(and(eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, target.id)))

    expect(remaining.length).toBe(0)
  })
})
