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
})
