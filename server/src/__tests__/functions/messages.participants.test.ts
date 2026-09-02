import { describe, expect, spyOn, test } from "bun:test"
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
import { UpdatesModel } from "@in/server/db/models/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"

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

  test("uses exact catch-up hints for direct additions without synthesizing inbox-opening actions", async () => {
    const space = await testUtils.createSpace("participant-live-dependency-space")
    const owner = await testUtils.createUser("participant-live-owner@example.com")
    const viewer = await testUtils.createUser("participant-live-viewer@example.com")
    const target = await testUtils.createUser("participant-live-target@example.com")
    if (!space || !owner || !viewer || !target) throw new Error("Failed to create live participant fixtures")
    await addSpaceMembers(space.id, [
      { userId: owner.id, role: "owner" },
      { userId: viewer.id },
      { userId: target.id },
    ])
    const chat = await testUtils.createChat(space.id, "Live Dependency Thread", "thread", false, owner.id)
    if (!chat) throw new Error("Failed to create live dependency chat")
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, viewer.id)

    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await addChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(owner.id))

      const participantCalls = push.mock.calls.filter(([, updates]) =>
        updates.some((update) => update.update.oneofKind === "chatHasNewUpdates"),
      )
      expect(participantCalls.map(([userId]) => userId).sort((a, b) => a - b)).toEqual(
        [owner.id, viewer.id, target.id].sort((a, b) => a - b),
      )
      expect(push.mock.calls.flatMap(([, updates]) => updates).some((update) =>
        update.update.oneofKind === "newChat" || update.update.oneofKind === "participantAdd",
      )).toBe(false)
      for (const [, updates] of participantCalls) {
        expect(updates).toHaveLength(1)
        const hint = updates[0]?.update
        if (hint?.oneofKind !== "chatHasNewUpdates") throw new Error("Expected targeted catch-up hint")
        expect(hint.chatHasNewUpdates.chatId).toBe(BigInt(chat.id))
        expect(hint.chatHasNewUpdates.updateSeq).toBeGreaterThan(0)
      }
    } finally {
      push.mockRestore()
    }
  })

  test.each(["chatHasNewUpdates", "userAddedToChat", "chatPermissions"])("keeps a committed add successful when %s delivery rejects", async (failedKind) => {
    const owner = await testUtils.createUser(`participant-failure-owner-${failedKind}@example.com`)
    const target = await testUtils.createUser(`participant-failure-target-${failedKind}@example.com`)
    const chat = await testUtils.createChat(null, "Participant Failure", "thread", false, owner.id)
    if (!chat) throw new Error("Failed to create participant failure chat")
    await testUtils.addParticipant(chat.id, owner.id)
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (_userId, updates) => {
      if (updates.some((update) => update.update.oneofKind === failedKind)) throw new Error("live delivery rejected")
    })
    try {
      const result = await addChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(owner.id))
      expect(result.participant?.userId).toBe(BigInt(target.id))
      const [participant] = await db.select().from(schema.chatParticipants).where(and(
        eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, target.id),
      ))
      expect(participant).toBeDefined()
      const [tail] = await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))
      const hints = push.mock.calls.flatMap(([, updates]) => updates).filter((update) => update.update.oneofKind === "chatHasNewUpdates")
      expect(hints.length).toBeGreaterThan(0)
      for (const hint of hints) {
        if (hint.update.oneofKind !== "chatHasNewUpdates") throw new Error("Expected hint")
        expect(hint.update.chatHasNewUpdates.updateSeq).toBe(tail?.updateSeq ?? 0)
      }
      if (failedKind === "chatPermissions") {
        expect(push.mock.calls.filter(([, updates]) => updates.some((update) => update.update.oneofKind === "chatPermissions"))).toHaveLength(2)
      }
    } finally {
      push.mockRestore()
    }
  })

  test.each(["participantDelete", "userRemovedFromChat"])("keeps a committed removal successful when %s delivery rejects", async (failedKind) => {
    const owner = await testUtils.createUser(`remove-failure-owner-${failedKind}@example.com`)
    const target = await testUtils.createUser(`remove-failure-target-${failedKind}@example.com`)
    const chat = await testUtils.createChat(null, "Removal Failure", "thread", false, owner.id)
    if (!chat) throw new Error("Failed to create removal failure chat")
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, target.id)
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (_userId, updates) => {
      if (updates.some((update) => update.update.oneofKind === failedKind)) throw new Error("live removal rejected")
    })
    try {
      await removeChatParticipant({ chatId: chat.id, userId: target.id }, makeFunctionContext(owner.id))
      const retained = await db.select().from(schema.chatParticipants).where(and(
        eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, target.id),
      ))
      expect(retained).toEqual([])
      const userRemovalCalls = push.mock.calls.filter(([userId, updates]) => userId === target.id && updates.some((update) => update.update.oneofKind === "userRemovedFromChat"))
      expect(userRemovalCalls).toHaveLength(failedKind === "userRemovedFromChat" ? 2 : 1)
      if (failedKind === "participantDelete") {
        expect(push.mock.calls.flatMap(([, updates]) => updates).some((update) => update.update.oneofKind === "chatHasNewUpdates")).toBe(true)
      }
    } finally {
      push.mockRestore()
    }
  })

  test("uses a targeted catch-up hint instead of a dependency-incomplete live group addition", async () => {
    const space = await testUtils.createSpace("participant-group-live-dependency-space")
    const owner = await testUtils.createUser("participant-group-live-owner@example.com")
    const viewer = await testUtils.createUser("participant-group-live-viewer@example.com")
    const member = await testUtils.createUser("participant-group-live-member@example.com")
    const otherMember = await testUtils.createUser("participant-group-live-other-member@example.com")
    if (!space || !owner || !viewer || !member || !otherMember) throw new Error("Failed to create live group fixtures")
    await addSpaceMembers(space.id, [
      { userId: owner.id, role: "owner" },
      { userId: viewer.id },
      { userId: member.id },
      { userId: otherMember.id },
    ])
    const createdGroup = await createUserGroup(
      { spaceId: space.id, name: "Live Group", userIds: [member.id, otherMember.id] },
      makeFunctionContext(owner.id),
    )
    const chat = await testUtils.createChat(space.id, "Live Group Dependency Thread", "thread", false, owner.id)
    if (!chat) throw new Error("Failed to create live group dependency chat")
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, viewer.id)

    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (userId, updates) => {
      if (userId === member.id && updates.some((update) => update.update.oneofKind === "userAddedToChat")) {
        throw new Error("One recipient is disconnected")
      }
    })
    try {
      await addChatParticipant(
        { chatId: chat.id, groupId: Number(createdGroup.group.id) },
        makeFunctionContext(owner.id),
      )

      const pushedUpdates = push.mock.calls.flatMap(([, updates]) => updates)
      expect(pushedUpdates.some((update) => update.update.oneofKind === "participantGroupAdd")).toBe(false)
      const hintCalls = push.mock.calls.filter(([, updates]) =>
        updates.some((update) => update.update.oneofKind === "chatHasNewUpdates"),
      )
      expect(hintCalls.map(([userId]) => userId).sort((a, b) => a - b)).toEqual(
        [owner.id, viewer.id, member.id, otherMember.id].sort((a, b) => a - b),
      )
      for (const [, updates] of hintCalls) {
        expect(updates).toHaveLength(1)
        const hint = updates[0]?.update
        if (hint?.oneofKind !== "chatHasNewUpdates") throw new Error("Expected chat catch-up hint")
        expect(Number(hint.chatHasNewUpdates.chatId)).toBe(chat.id)
        expect(Number(hint.chatHasNewUpdates.peerId?.type.oneofKind === "chat"
          ? hint.chatHasNewUpdates.peerId.type.chat.chatId
          : 0n)).toBe(chat.id)
        expect(hint.chatHasNewUpdates.updateSeq).toBeGreaterThan(0)
      }
      const accessCalls = push.mock.calls.filter(([, updates]) => updates.some((update) => update.update.oneofKind === "userAddedToChat"))
      expect(accessCalls.filter(([userId]) => userId === member.id)).toHaveLength(2)
      expect(accessCalls.filter(([userId]) => userId === otherMember.id)).toHaveLength(1)
    } finally {
      push.mockRestore()
    }
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
    expect(createdGroup.users.map((user) => Number(user.id))).toEqual([member.id])

    const chat = await testUtils.createChat(space.id, "Private Group Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, creator.id)

    await expect(AccessGuards.ensureChatAccess(chat, member.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })

    const added = await addChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(creator.id))
    expect(Number(added.groupParticipant?.groupId)).toBe(groupId)
    expect(added.group?.name).toBe("Eng")
    expect(added.users?.map((user) => Number(user.id))).toEqual([member.id])

    await expect(AccessGuards.ensureChatAccess(chat, member.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(chat, outsider.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })

    const participants = await getChatParticipants({ chatId: chat.id }, makeFunctionContext(creator.id))
    expect(participants.groupParticipants.map((group) => Number(group.groupId))).toContain(groupId)
    expect(participants.groups.map((group) => group.name)).toContain("Eng")
    expect(participants.users.map((user) => Number(user.id))).toContain(member.id)

    await removeChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(creator.id))
    await expect(AccessGuards.ensureChatAccess(chat, member.id)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })
  })

  test("emits user access events only for effective transitions", async () => {
    const space = await testUtils.createSpace("participant-effective-access-space")
    const owner = await testUtils.createUser("effective-access-owner@example.com")
    const member = await testUtils.createUser("effective-access-member@example.com")
    if (!space || !owner || !member) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [
      { userId: owner.id, role: "owner" },
      { userId: member.id },
    ])
    const createdGroup = await createUserGroup(
      { spaceId: space.id, name: "Effective", userIds: [member.id] },
      makeFunctionContext(owner.id),
    )
    const groupId = Number(createdGroup.group.id)
    const chat = await testUtils.createChat(space.id, "Effective Access Thread", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)

    await addChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(owner.id))
    await addChatParticipant({ chatId: chat.id, userId: member.id }, makeFunctionContext(owner.id))
    await removeChatParticipant({ chatId: chat.id, userId: member.id }, makeFunctionContext(owner.id))

    const beforeFinalLoss = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, member.id)))
    expect(
      beforeFinalLoss
        .map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)
        .filter((kind) => kind === "userAddedToChat" || kind === "userRemovedFromChat"),
    ).toEqual(["userAddedToChat"])

    await removeChatParticipant({ chatId: chat.id, groupId }, makeFunctionContext(owner.id))

    const afterFinalLoss = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, member.id)))
      .orderBy(schema.updates.seq)
    const accessPayloads = afterFinalLoss
      .map((row) => UpdatesModel.decrypt(row).payload.update)
      .filter((payload) => payload.oneofKind === "userAddedToChat" || payload.oneofKind === "userRemovedFromChat")

    expect(accessPayloads.map((payload) => payload.oneofKind)).toEqual([
      "userAddedToChat",
      "userRemovedFromChat",
    ])
    const removed = accessPayloads[1]
    expect(removed?.oneofKind).toBe("userRemovedFromChat")
    if (removed?.oneofKind === "userRemovedFromChat") {
      expect(Number(removed.userRemovedFromChat.chatId)).toBe(chat.id)
      expect(Number(removed.userRemovedFromChat.groupId)).toBe(groupId)
    }
  })

  test("refreshes child-thread permissions for direct and group grant changes without child access events", async () => {
    const space = await testUtils.createSpace("participant-child-permission-space")
    const owner = await testUtils.createUser("child-permission-owner@example.com")
    const directMember = await testUtils.createUser("child-permission-direct@example.com")
    const groupMember = await testUtils.createUser("child-permission-group@example.com")
    if (!space || !owner || !directMember || !groupMember) throw new Error("Failed to create test data")

    await addSpaceMembers(space.id, [
      { userId: owner.id, role: "owner" },
      { userId: directMember.id },
      { userId: groupMember.id },
    ])
    const createdGroup = await createUserGroup(
      { spaceId: space.id, name: "Child editors", userIds: [groupMember.id] },
      makeFunctionContext(owner.id),
    )
    const groupId = Number(createdGroup.group.id)
    const parent = await testUtils.createChat(space.id, "Permission Parent", "thread", false, owner.id)
    if (!parent) throw new Error("Parent chat not created")
    await testUtils.addParticipant(parent.id, owner.id)
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "anchor" })
    const [child] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Permission Child",
        spaceId: space.id,
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parent.id,
        parentMessageId: 1,
      })
      .returning()
    if (!child) throw new Error("Child chat not created")

    await addChatParticipant({ chatId: child.id, userId: directMember.id }, makeFunctionContext(owner.id))
    await removeChatParticipant({ chatId: child.id, userId: directMember.id }, makeFunctionContext(owner.id))
    await addChatParticipant({ chatId: child.id, groupId }, makeFunctionContext(owner.id))
    await removeChatParticipant({ chatId: child.id, groupId }, makeFunctionContext(owner.id))

    for (const userId of [directMember.id, groupMember.id]) {
      const userUpdates = await db
        .select()
        .from(schema.updates)
        .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, userId)))
        .orderBy(schema.updates.seq)
      const payloads = userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update)
      expect(
        payloads.filter((payload) =>
          payload.oneofKind === "userAddedToChat" || payload.oneofKind === "userRemovedFromChat"
        ),
      ).toEqual([])
      expect(
        payloads.flatMap((payload) =>
          payload.oneofKind === "userChatPermissions"
            ? [{
                chatId: Number(payload.userChatPermissions.chatId),
                canUpdateInfo: payload.userChatPermissions.permissions?.canUpdateInfo,
              }]
            : []
        ),
      ).toEqual([
        { chatId: child.id, canUpdateInfo: true },
        { chatId: child.id, canUpdateInfo: false },
      ])
    }
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

    const updatedGroup = await updateUserGroup(
      {
        groupId,
        name: "Support",
        userIds: [newMember.id],
      },
      makeFunctionContext(creator.id),
    )
    expect(updatedGroup.users.map((user) => Number(user.id))).toEqual([newMember.id])

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
