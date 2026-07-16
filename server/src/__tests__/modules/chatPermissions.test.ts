import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import {
  prepareChatPermissionUpdates,
  prepareSpaceChatPermissionUpdates,
} from "@in/server/modules/authorization/chatPermissionUpdates"
import { resolveChatPermissionsForUsers } from "@in/server/modules/authorization/chatPermissions"
import { Sync } from "@in/server/modules/updates/sync"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { and, eq } from "drizzle-orm"

describe("chat permissions", () => {
  setupTestLifecycle()

  test("resolves reply-thread participant and admin permissions per user", async () => {
    const owner = await testUtils.createUser("chat-permissions-owner@example.com")
    const participant = await testUtils.createUser("chat-permissions-participant@example.com")
    const admin = await testUtils.createUser("chat-permissions-admin@example.com")
    const member = await testUtils.createUser("chat-permissions-member@example.com")
    const space = await testUtils.createSpace("Chat Permissions Space")
    if (!owner || !participant || !admin || !member || !space) {
      throw new Error("Failed to create chat permission fixtures")
    }

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: participant.id, role: "member" },
      { spaceId: space.id, userId: admin.id, role: "admin" },
      { spaceId: space.id, userId: member.id, role: "member" },
    ])

    const parent = await testUtils.createChat(space.id, "Private Parent", "thread", false, owner.id)
    if (!parent) {
      throw new Error("Failed to create parent chat")
    }
    await testUtils.addParticipant(parent.id, owner.id)
    await testUtils.addParticipant(parent.id, participant.id)
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "anchor" })

    const [reply] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        publicThread: false,
        parentChatId: parent.id,
        parentMessageId: 1,
        title: "Re: anchor",
      })
      .returning()
    if (!reply) {
      throw new Error("Failed to create reply thread")
    }

    const userIds = [participant.id, admin.id, member.id]
    const permissionsByUserId = await resolveChatPermissionsForUsers([reply], userIds)
    expect(permissionsByUserId.get(participant.id)?.get(reply.id)?.canUpdateInfo).toBe(true)
    expect(permissionsByUserId.get(admin.id)?.get(reply.id)?.canUpdateInfo).toBe(true)
    expect(permissionsByUserId.get(member.id)?.get(reply.id)?.canUpdateInfo).toBe(false)

    const chatsByUserId = await Encoders.chatForUsers(reply, userIds)
    expect(chatsByUserId.get(participant.id)?.permissions?.canUpdateInfo).toBe(true)
    expect(chatsByUserId.get(admin.id)?.permissions?.canUpdateInfo).toBe(true)
    expect(chatsByUserId.get(member.id)?.permissions?.canUpdateInfo).toBe(false)
  })

  test("allows group grants on reply threads without broadening top-level private edits", async () => {
    const owner = await testUtils.createUser("chat-permissions-group-owner@example.com")
    const groupMember = await testUtils.createUser("chat-permissions-group-member@example.com")
    const space = await testUtils.createSpace("Chat Permissions Group Space")
    if (!owner || !groupMember || !space) {
      throw new Error("Failed to create group permission fixtures")
    }

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: groupMember.id, role: "member" },
    ])
    const [group] = await db
      .insert(schema.userGroups)
      .values({ spaceId: space.id, name: "Editors", createdBy: owner.id })
      .returning()
    if (!group) {
      throw new Error("Failed to create user group")
    }
    await db.insert(schema.userGroupMembers).values({ groupId: group.id, userId: groupMember.id })

    const parent = await testUtils.createChat(space.id, "Group Parent", "thread", false, owner.id)
    if (!parent) {
      throw new Error("Failed to create group parent chat")
    }
    await db.insert(schema.chatParticipantGroups).values({ chatId: parent.id, groupId: group.id })
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "anchor" })
    const [reply] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        publicThread: false,
        parentChatId: parent.id,
        parentMessageId: 1,
        title: "Re: anchor",
      })
      .returning()
    if (!reply) {
      throw new Error("Failed to create group reply thread")
    }

    const permissions = await resolveChatPermissionsForUsers([parent, reply], [groupMember.id])
    expect(permissions.get(groupMember.id)?.get(parent.id)?.canUpdateInfo).toBe(false)
    expect(permissions.get(groupMember.id)?.get(reply.id)?.canUpdateInfo).toBe(true)
  })

  test("allows both direct-message members to edit its reply thread", async () => {
    const userA = await testUtils.createUser("chat-permissions-dm-a@example.com")
    const userB = await testUtils.createUser("chat-permissions-dm-b@example.com")
    if (!userA || !userB) {
      throw new Error("Failed to create DM users")
    }

    const dm = await testUtils.createPrivateChat(userA, userB)
    if (!dm) {
      throw new Error("Failed to create DM")
    }
    await db.insert(schema.messages).values({ chatId: dm.id, messageId: 1, fromId: userA.id, text: "anchor" })
    const [reply] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        publicThread: false,
        parentChatId: dm.id,
        parentMessageId: 1,
        title: "Re: anchor",
      })
      .returning()
    if (!reply) {
      throw new Error("Failed to create DM reply thread")
    }

    const permissions = await resolveChatPermissionsForUsers([reply], [userA.id, userB.id])
    expect(permissions.get(userA.id)?.get(reply.id)?.canUpdateInfo).toBe(true)
    expect(permissions.get(userB.id)?.get(reply.id)?.canUpdateInfo).toBe(true)
  })

  test("persists permission changes for a thread and its reply descendants", async () => {
    const user = await testUtils.createUser("chat-permissions-refresh@example.com")
    if (!user) {
      throw new Error("Failed to create permission refresh user")
    }

    const parent = await testUtils.createChat(null, "Permission Parent", "thread", false, user.id)
    if (!parent) {
      throw new Error("Failed to create permission refresh parent")
    }
    await testUtils.addParticipant(parent.id, user.id)
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: user.id, text: "anchor" })
    const [reply] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        publicThread: false,
        parentChatId: parent.id,
        parentMessageId: 1,
        title: "Re: anchor",
      })
      .returning()
    if (!reply) {
      throw new Error("Failed to create permission refresh reply")
    }

    const granted = await prepareChatPermissionUpdates({
      userIds: [user.id],
      chatIds: [parent.id],
    })
    expect(granted).toHaveLength(2)
    expect(granted.every(({ update }) =>
      update.update.oneofKind === "chatPermissions" && update.update.chatPermissions.permissions?.canUpdateInfo === true
    )).toBe(true)

    await db
      .delete(schema.chatParticipants)
      .where(and(eq(schema.chatParticipants.chatId, parent.id), eq(schema.chatParticipants.userId, user.id)))

    const revoked = await prepareChatPermissionUpdates({
      userIds: [user.id],
      chatIds: [parent.id],
    })
    expect(revoked).toHaveLength(2)
    expect(revoked.every(({ update }) =>
      update.update.oneofKind === "chatPermissions" && update.update.chatPermissions.permissions?.canUpdateInfo === false
    )).toBe(true)

    const { updates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.User, userId: user.id },
      seqStart: 0,
      limit: 10,
    })
    const inflated = Sync.inflateUserUpdates(updates)
    expect(inflated).toHaveLength(4)
    expect(inflated.map((update) => update.update.oneofKind)).toEqual([
      "chatPermissions",
      "chatPermissions",
      "chatPermissions",
      "chatPermissions",
    ])
  })

  test("limits space-role refreshes to public roots and reply threads", async () => {
    const user = await testUtils.createUser("chat-permissions-space-refresh@example.com")
    const space = await testUtils.createSpace("Chat Permissions Refresh Space")
    if (!user || !space) {
      throw new Error("Failed to create space permission refresh fixtures")
    }
    await db.insert(schema.members).values({ spaceId: space.id, userId: user.id, role: "admin" })

    const privateRoot = await testUtils.createChat(space.id, "Private Root", "thread", false, user.id)
    const publicRoot = await testUtils.createChat(space.id, "Public Root", "thread", true, user.id)
    if (!privateRoot || !publicRoot) {
      throw new Error("Failed to create space permission refresh roots")
    }
    await testUtils.addParticipant(privateRoot.id, user.id)
    await db.insert(schema.messages).values({
      chatId: privateRoot.id,
      messageId: 1,
      fromId: user.id,
      text: "anchor",
    })
    const [reply] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        spaceId: space.id,
        publicThread: false,
        parentChatId: privateRoot.id,
        parentMessageId: 1,
        title: "Re: anchor",
      })
      .returning()
    if (!reply) {
      throw new Error("Failed to create space permission refresh reply")
    }

    const updates = await prepareSpaceChatPermissionUpdates({ userIds: [user.id], spaceId: space.id })
    const updatedChatIds = updates.flatMap(({ update }) =>
      update.update.oneofKind === "chatPermissions" ? [Number(update.update.chatPermissions.chatId)] : []
    )

    expect(new Set(updatedChatIds)).toEqual(new Set([publicRoot.id, reply.id]))
    expect(updatedChatIds).not.toContain(privateRoot.id)
  })
})
