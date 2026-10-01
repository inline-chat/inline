import { describe, expect, test } from "bun:test"
import { db, schema } from "@in/server/db"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { setupTestLifecycle, testUtils } from "../setup"

describe("batched chat access projection", () => {
  setupTestLifecycle()

  test("matches legacy nullable public access and fences direct child grants by owning Space membership", async () => {
    const allowed = await testUtils.createUser("projection-null-access@example.com")
    const restricted = await testUtils.createUser("projection-false-access@example.com")
    const outsider = await testUtils.createUser("projection-outsider@example.com")
    const space = await testUtils.createSpace("Projection Authority")
    if (!space) throw new Error("Expected Space")
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: allowed.id, canAccessPublicChats: null },
      { spaceId: space.id, userId: restricted.id, canAccessPublicChats: false },
    ])
    const root = await testUtils.createChat(space.id, "Public root", "thread", true)
    if (!root) throw new Error("Expected root chat")
    const [child] = await db.insert(schema.chats).values({
      type: "thread",
      title: "Inherited child",
      parentChatId: root.id,
      publicThread: false,
    }).returning()
    if (!child) throw new Error("Expected child chat")
    await db.insert(schema.chatParticipants).values({ chatId: child.id, userId: outsider.id })

    await expect(AccessGuards.ensureChatAccess(root, allowed.id)).resolves.toBeUndefined()
    await expect(AccessGuards.ensureChatAccess(root, restricted.id)).rejects.toBeDefined()
    await expect(AccessGuards.ensureChatAccess(child, outsider.id)).rejects.toBeDefined()
    const access = await db.transaction((tx) => getEffectiveChatAccessUserIds(
      tx,
      [root.id, child.id],
      { userIds: [allowed.id, restricted.id, outsider.id] },
    ))
    expect([...access.get(root.id) ?? []]).toEqual([allowed.id])
    expect([...access.get(child.id) ?? []]).toEqual([allowed.id])
  })

  test("matches current guards for malformed group grants while retaining valid direct and group access", async () => {
    const owner = await testUtils.createUser("projection-group-owner@example.test")
    const reader = await testUtils.createUser("projection-group-reader@example.test")
    const owningSpace = await testUtils.createSpace("Grant owning Space")
    const otherSpace = await testUtils.createSpace("Unrelated group Space")
    if (!owningSpace || !otherSpace) throw new Error("Spaces not created")
    await db.insert(schema.members).values([
      { userId: reader.id, spaceId: owningSpace.id, canAccessPublicChats: false },
      { userId: reader.id, spaceId: otherSpace.id },
    ])
    const [group, localGroup] = await db.insert(schema.userGroups).values([
      { spaceId: otherSpace.id, name: "Scoped readers", createdBy: owner.id },
      { spaceId: owningSpace.id, name: "Public readers", createdBy: owner.id },
    ]).returning()
    if (!group || !localGroup) throw new Error("Groups not created")
    await db.insert(schema.userGroupMembers).values([
      { groupId: group.id, userId: reader.id },
      { groupId: localGroup.id, userId: reader.id },
    ])
    const chatRows = await db.insert(schema.chats).values([
      { type: "thread", title: "Wrong Space grant", spaceId: owningSpace.id, publicThread: false },
      { type: "thread", title: "Public group grant", spaceId: owningSpace.id, publicThread: true },
      { type: "thread", title: "Home group grant", publicThread: false },
      { type: "thread", title: "Nullable group grant", spaceId: otherSpace.id, publicThread: null },
      { type: "thread", title: "Valid group grant", spaceId: otherSpace.id, publicThread: false },
      { type: "thread", title: "Valid direct grant", spaceId: owningSpace.id, publicThread: false },
    ]).returning()
    const [wrongSpace, publicChat, homeChat, nullableChat, validGroup, validDirect] = chatRows
    if (!wrongSpace || !publicChat || !homeChat || !nullableChat || !validGroup || !validDirect) {
      throw new Error("Chats not created")
    }
    await db.insert(schema.chatParticipantGroups).values([
      ...[wrongSpace, homeChat, nullableChat, validGroup].map((chat) => ({ chatId: chat.id, groupId: group.id })),
      { chatId: publicChat.id, groupId: localGroup.id },
    ])
    await testUtils.addParticipant(validDirect.id, reader.id)
    const [inheritedDenied] = await db.insert(schema.chats).values({
      type: "thread", title: "Invalid root grant child", spaceId: owningSpace.id, parentChatId: wrongSpace.id,
    }).returning()
    if (!inheritedDenied) throw new Error("Child not created")
    const denied = [wrongSpace, publicChat, homeChat, nullableChat, inheritedDenied]
    for (const chat of denied) {
      await expect(AccessGuards.ensureChatAccess(chat, reader.id)).rejects.toBeDefined()
    }
    for (const chat of [validGroup, validDirect]) {
      await expect(AccessGuards.ensureChatAccess(chat, reader.id)).resolves.toBeUndefined()
    }
    const access = await getEffectiveChatAccessUserIds(db, [...denied, validGroup, validDirect].map((chat) => chat.id), {
      userIds: [reader.id],
    })
    for (const chat of denied) expect([...access.get(chat.id) ?? []]).toEqual([])
    for (const chat of [validGroup, validDirect]) expect([...access.get(chat.id) ?? []]).toEqual([reader.id])
  })

  test("retained participant rows cannot grant access to someone else's private DM", async () => {
    const owner = await testUtils.createUser("projection-dm-owner@example.test")
    const peer = await testUtils.createUser("projection-dm-peer@example.test")
    const outsider = await testUtils.createUser("projection-dm-outsider@example.test")
    const dm = await testUtils.createPrivateChat(owner, peer)
    if (!dm) throw new Error("Private chat not created")
    await testUtils.addParticipant(dm.id, outsider.id)
    await expect(AccessGuards.ensureChatAccess(dm, outsider.id)).rejects.toBeDefined()
    const access = await getEffectiveChatAccessUserIds(db, [dm.id], { userIds: [owner.id, peer.id, outsider.id] })
    expect([...access.get(dm.id) ?? []].sort((a, b) => a - b)).toEqual([owner.id, peer.id].sort((a, b) => a - b))
  })
})
