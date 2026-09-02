import { describe, expect, test } from "bun:test"
import { and, eq, isNull } from "drizzle-orm"
import type { HandlerContext } from "../../controllers/helpers"
import { db } from "../../db"
import { chats, dialogs, files, users } from "../../db/schema"
import { handler } from "../../methods/createPrivateChat"
import { setupTestLifecycle, testUtils } from "../setup"

describe("createPrivateChat", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("creates and reuses one private DM without a Home thread", async () => {
    const currentUser = await testUtils.createUser("create-dm-current@example.com")
    const peerUser = await testUtils.createUser("create-dm-peer@example.com")
    if (!currentUser || !peerUser) throw new Error("Failed to create users")

    const fileUniqueId = `create-dm-profile-${peerUser.id}`
    const [photo] = await db
      .insert(files)
      .values({
        fileUniqueId,
        userId: peerUser.id,
        fileType: "photo",
        mimeType: "image/jpeg",
        fileSize: 123,
      })
      .returning()
    if (!photo) throw new Error("Failed to create peer profile photo")
    await db.update(users).set({ photoFileId: photo.id }).where(eq(users.id, peerUser.id))

    const first = await handler({ userId: String(peerUser.id) }, makeContext(currentUser.id))
    const second = await handler({ userId: String(peerUser.id) }, makeContext(currentUser.id))

    expect(first.chat.type).toBe("private")
    expect(first.chat.id).toBe(second.chat.id)
    expect(first.user.id).toBe(peerUser.id)
    expect(first.user.photo?.[0]?.fileUniqueId).toBe(fileUniqueId)

    const minUserId = Math.min(currentUser.id, peerUser.id)
    const maxUserId = Math.max(currentUser.id, peerUser.id)
    const privateChats = await db
      .select()
      .from(chats)
      .where(
        and(
          eq(chats.type, "private"),
          eq(chats.minUserId, minUserId),
          eq(chats.maxUserId, maxUserId),
        ),
      )
    expect(privateChats).toHaveLength(1)

    const dmDialogs = await db.select().from(dialogs).where(eq(dialogs.chatId, privateChats[0]!.id))
    expect(dmDialogs).toHaveLength(2)

    const mistakenHomeThreads = await db
      .select()
      .from(chats)
      .where(and(eq(chats.type, "thread"), isNull(chats.spaceId), eq(chats.createdBy, currentUser.id)))
    expect(mistakenHomeThreads).toHaveLength(0)
  })
})
