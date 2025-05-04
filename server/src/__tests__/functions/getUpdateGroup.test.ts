import { describe, test, expect } from "bun:test"
import { getUpdateGroup, getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq } from "drizzle-orm"
import type { TPeerInfo } from "@in/server/api-types"
import type { InputPeer } from "@in/protocol/core"

function makeInputPeerUser(userId: number): InputPeer {
  return { type: { oneofKind: "user", user: { userId: BigInt(userId) } } }
}
function makeInputPeerChat(chatId: number): InputPeer {
  return { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } }
}

describe("getUpdateGroup & getUpdateGroupFromInputPeer", () => {
  setupTestLifecycle()

  test("returns correct userIds for private chat (DM)", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("DM Test Space", ["a@ex.com", "b@ex.com"])
    const [userA, userB] = users
    // Create DM chat
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Chat not created")
    // TPeerInfo for DM
    const peer: TPeerInfo = { userId: userB.id }
    const context = { currentUserId: userA.id }
    const group = await getUpdateGroup(peer, context)
    expect(group.type).toBe("users")
    expect((group as any).userIds.sort()).toEqual([userA.id, userB.id].sort())
  })

  test("returns correct userIds for saved message (self chat)", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Self Space", ["self@ex.com"])
    const user = users[0]
    const chat = await testUtils.createPrivateChat(user, user)
    if (!chat) throw new Error("Chat not created")
    // TPeerInfo for self
    const peer: TPeerInfo = { userId: user.id }
    const context = { currentUserId: user.id }
    const group = await getUpdateGroup(peer, context)
    expect(group.type).toBe("users")
    expect((group as any).userIds).toEqual([user.id])
  })

  test("returns all space members for public thread", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Thread Space", [
      "a@ex.com",
      "b@ex.com",
      "c@ex.com",
    ])
    const chat = await testUtils.createChat(space.id, "Public Thread", "thread")
    if (!chat) throw new Error("Chat not created")
    // Patch chat to be public
    await db.update(schema.chats).set({ publicThread: true }).where(eq(schema.chats.id, chat!.id)).execute()
    const peer: TPeerInfo = { threadId: chat!.id }
    const context = { currentUserId: users[0].id }
    const group = await getUpdateGroup(peer, context)
    expect(group.type).toBe("users")
    expect((group as any).userIds.sort()).toEqual(users.map((u) => u.id).sort())
  })

  test("returns only participants for private thread", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Private Thread Space", [
      "a@ex.com",
      "b@ex.com",
      "c@ex.com",
    ])
    const chat = await testUtils.createChat(space.id, "Private Thread", "thread")
    if (!chat) throw new Error("Chat not created")
    // Patch chat to be private
    await db.update(schema.chats).set({ publicThread: false }).where(eq(schema.chats.id, chat!.id)).execute()
    // Add only userA and userB as participants
    await testUtils.addParticipant(chat!.id, users[0].id)
    await testUtils.addParticipant(chat!.id, users[1].id)
    const peer: TPeerInfo = { threadId: chat!.id }
    const context = { currentUserId: users[0].id }
    const group = await getUpdateGroup(peer, context)
    expect(group.type).toBe("users")
    expect((group as any).userIds.sort()).toEqual([users[0].id, users[1].id].sort())
  })

  test("getUpdateGroupFromInputPeer: user peer", async () => {
    const { users } = await testUtils.createSpaceWithMembers("InputPeer User", ["a@ex.com", "b@ex.com"])
    const [userA, userB] = users
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Chat not created")
    const inputPeer = makeInputPeerChat(chat!.id)
    const context = { currentUserId: userA.id }
    const group = await getUpdateGroupFromInputPeer(inputPeer, context)
    expect(group.type).toBe("users")
    expect((group as any).userIds.sort()).toEqual([userA.id, userB.id].sort())
  })

  test("getUpdateGroupFromInputPeer: chat peer (thread)", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("InputPeer Thread", ["a@ex.com", "b@ex.com"])
    const chat = await testUtils.createChat(space.id, "Thread Chat", "thread")
    if (!chat) throw new Error("Chat not created")
    await db.update(schema.chats).set({ publicThread: true }).where(eq(schema.chats.id, chat!.id)).execute()
    const inputPeer = makeInputPeerChat(chat!.id)
    const context = { currentUserId: users[0].id }
    const group = await getUpdateGroupFromInputPeer(inputPeer, context)
    expect(group.type).toBe("users")
    expect((group as any).userIds.sort()).toEqual(users.map((u) => u.id).sort())
  })
})
