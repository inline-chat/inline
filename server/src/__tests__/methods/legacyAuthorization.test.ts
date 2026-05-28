import { describe, expect, test } from "bun:test"
import { handler as addMember } from "@in/server/methods/addMember"
import { handler as addReaction } from "@in/server/methods/addReaction"
import { handler as createThread } from "@in/server/methods/createThread"
import { handler as deleteMessage } from "@in/server/methods/deleteMessage"
import { handler as getChatHistory } from "@in/server/methods/getChatHistory"
import { handler as sendMessage } from "@in/server/methods/sendMessage"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import type { HandlerContext } from "@in/server/controllers/helpers"

const makeContext = (userId: number): HandlerContext => ({
  currentUserId: userId,
  currentSessionId: 1,
  ip: "127.0.0.1",
})

describe("legacy method authorization", () => {
  setupTestLifecycle()

  test("requires a space admin to add members", async () => {
    const space = await testUtils.createSpace("legacy-add-member-space")
    const owner = await testUtils.createUser("legacy-add-owner@example.com")
    const member = await testUtils.createUser("legacy-add-member@example.com")
    const target = await testUtils.createUser("legacy-add-target@example.com")
    if (!space || !owner || !member || !target) throw new Error("Failed to create test data")

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: member.id, role: "member" },
    ])

    await expect(
      addMember({ spaceId: space.id, userId: target.id }, makeContext(member.id)),
    ).rejects.toMatchObject({ type: "SPACE_ADMIN_REQUIRED" })

    const result = await addMember({ spaceId: space.id, userId: target.id }, makeContext(owner.id))
    expect(result.member.userId).toBe(target.id)
  })

  test("requires space membership to create legacy public threads", async () => {
    const space = await testUtils.createSpace("legacy-create-thread-space")
    const outsider = await testUtils.createUser("legacy-create-thread-outsider@example.com")
    if (!space || !outsider) throw new Error("Failed to create test data")

    await expect(
      createThread({ spaceId: space.id, title: "Should Not Exist" }, makeContext(outsider.id)),
    ).rejects.toMatchObject({ type: "SPACE_INVALID" })
  })

  test("rejects legacy message actions for private space thread non-participants", async () => {
    const space = await testUtils.createSpace("legacy-message-space")
    const owner = await testUtils.createUser("legacy-message-owner@example.com")
    const viewer = await testUtils.createUser("legacy-message-viewer@example.com")
    if (!space || !owner || !viewer) throw new Error("Failed to create test data")

    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: viewer.id, role: "member" },
    ])

    const { chat, msg } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user: owner,
      title: "Private Space Thread",
      isPublic: false,
    })

    await expect(
      getChatHistory({ peerThreadId: chat.id, limit: 10 }, makeContext(viewer.id)),
    ).rejects.toMatchObject({ type: "PEER_INVALID" })

    await expect(
      sendMessage({ peerThreadId: chat.id, text: "not allowed" }, makeContext(viewer.id)),
    ).rejects.toMatchObject({ type: "PEER_INVALID" })

    await expect(
      addReaction({ chatId: chat.id, messageId: msg.messageId, emoji: "+1" }, makeContext(viewer.id)),
    ).rejects.toMatchObject({ type: "PEER_INVALID" })

    await expect(
      deleteMessage({ chatId: chat.id, messageId: msg.messageId, peerThreadId: chat.id }, makeContext(viewer.id)),
    ).rejects.toMatchObject({ type: "PEER_INVALID" })
  })
})
