import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { messages, users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { resolveProviderActionContext } from "./providerActionContext"

describe("provider action context", () => {
  setupTestLifecycle()

  test("binds the accessible chat, message, space, and peer", async () => {
    const { space, users: members } = await testUtils.createSpaceWithMembers(
      "Provider Context",
      ["provider-context@example.com"],
    )
    const user = members[0]
    if (!user) throw new Error("user not created")
    const { chat, msg } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user,
      isPublic: false,
    })

    const result = await resolveProviderActionContext({
      chatId: chat.id,
      messageId: msg.messageId,
      currentUserId: user.id,
      claimedSpaceId: space.id,
    })

    expect(result.spaceId).toBe(space.id)
    expect(result.message.globalId).toBe(msg.globalId)
    expect(result.peerId).toEqual({ threadId: chat.id })
  })

  test("rejects a space member without access to the private thread", async () => {
    const { space, users: members } = await testUtils.createSpaceWithMembers(
      "Private Provider Context",
      ["private-context-owner@example.com", "private-context-member@example.com"],
    )
    const owner = members[0]
    const member = members[1]
    if (!owner || !member) throw new Error("users not created")
    const { chat, msg } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user: owner,
      isPublic: false,
    })

    await expect(resolveProviderActionContext({
      chatId: chat.id,
      messageId: msg.messageId,
      currentUserId: member.id,
      claimedSpaceId: space.id,
    })).rejects.toBeDefined()
  })

  test("rejects bot users and mismatched claimed spaces", async () => {
    const { space, users: members } = await testUtils.createSpaceWithMembers(
      "Bot Provider Context",
      ["bot-provider-context@example.com"],
    )
    const user = members[0]
    if (!user) throw new Error("user not created")
    const { chat, msg } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user,
      isPublic: false,
    })

    await expect(resolveProviderActionContext({
      chatId: chat.id,
      messageId: msg.messageId,
      currentUserId: user.id,
      claimedSpaceId: space.id + 1,
    })).rejects.toBeDefined()

    await db.update(users).set({ bot: true }).where(eq(users.id, user.id))
    await expect(resolveProviderActionContext({
      chatId: chat.id,
      messageId: msg.messageId,
      currentUserId: user.id,
      claimedSpaceId: space.id,
    })).rejects.toBeDefined()
  })

  test("allows an accessible DM to use an explicitly selected member space", async () => {
    const { space, users: members } = await testUtils.createSpaceWithMembers(
      "DM Provider Context",
      ["dm-provider-a@example.com", "dm-provider-b@example.com"],
    )
    const user = members[0]
    const other = members[1]
    if (!user || !other) throw new Error("users not created")
    const chat = await testUtils.createPrivateChat(user, other)
    if (!chat) throw new Error("chat not created")
    const [message] = await db.insert(messages).values({
      messageId: 1,
      chatId: chat.id,
      fromId: other.id,
      text: "Create this task",
    }).returning()
    if (!message) throw new Error("message not created")

    const result = await resolveProviderActionContext({
      chatId: chat.id,
      messageId: message.messageId,
      currentUserId: user.id,
      claimedSpaceId: space.id,
    })

    expect(result.spaceId).toBe(space.id)
    expect(result.peerId).toEqual({ userId: other.id })
  })
})
