import { describe, expect, test } from "bun:test"
import { moveThread } from "@in/server/functions/messages.moveThread"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils, defaultTestContext } from "../setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { and, eq, inArray } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"

describe("messages.moveThread", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): FunctionContext => ({
    currentSessionId: defaultTestContext.sessionId,
    currentUserId: userId,
  })

  test("moves a private home thread into a space (creator)", async () => {
    const space = await testUtils.createSpace("Move Home -> Space")
    if (!space) throw new Error("Failed to create space")

    const creator = await testUtils.createUser("move-home-creator@example.com")
    const other = await testUtils.createUser("move-home-other@example.com")

    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: space.id, role: "member" },
      { userId: other.id, spaceId: space.id, role: "member" },
    ])

    const chat = await testUtils.createChat(null, "Home Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Failed to create chat")

    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, other.id)

    const result = await moveThread({ chatId: chat.id, spaceId: space.id }, makeContext(creator.id))

    expect(result.chat.spaceId).toBe(space.id)
    expect(result.chat.threadNumber).not.toBeNull()
    expect(result.chat.publicThread).toBe(false)

    const dialogs = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, chat.id), inArray(schema.dialogs.userId, [creator.id, other.id])))

    expect(dialogs).toHaveLength(2)
    expect(dialogs.every((d) => d.spaceId === space.id)).toBe(true)
  })

  test("moves a private space thread to home (space admin)", async () => {
    const space = await testUtils.createSpace("Move Space -> Home")
    if (!space) throw new Error("Failed to create space")

    const creator = await testUtils.createUser("move-space-creator@example.com")
    const admin = await testUtils.createUser("move-space-admin@example.com")
    const participant = await testUtils.createUser("move-space-participant@example.com")

    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: space.id, role: "member" },
      { userId: admin.id, spaceId: space.id, role: "admin" },
      { userId: participant.id, spaceId: space.id, role: "member" },
    ])

    const chat = await testUtils.createChat(space.id, "Space Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Failed to create chat")
    await db.update(schema.chats).set({ threadNumber: 1 }).where(eq(schema.chats.id, chat.id))

    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, participant.id)

    const result = await moveThread({ chatId: chat.id, spaceId: null }, makeContext(admin.id))

    expect(result.chat.spaceId).toBeNull()
    expect(result.chat.threadNumber).toBeNull()

    const dialogs = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, chat.id), inArray(schema.dialogs.userId, [creator.id, participant.id])))

    expect(dialogs).toHaveLength(2)
    expect(dialogs.every((d) => d.spaceId == null)).toBe(true)
  })

  test("rejects cross-space move (space -> different space)", async () => {
    const spaceA = await testUtils.createSpace("Space A")
    const spaceB = await testUtils.createSpace("Space B")
    if (!spaceA || !spaceB) throw new Error("Failed to create spaces")

    const creator = await testUtils.createUser("cross-space-creator@example.com")
    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: spaceA.id, role: "member" },
      { userId: creator.id, spaceId: spaceB.id, role: "member" },
    ])

    const chat = await testUtils.createChat(spaceA.id, "Space Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Failed to create chat")
    await testUtils.addParticipant(chat.id, creator.id)

    await expect(moveThread({ chatId: chat.id, spaceId: spaceB.id }, makeContext(creator.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })
  })

  test("rejects moving public threads", async () => {
    const space = await testUtils.createSpace("Public Move Reject")
    if (!space) throw new Error("Failed to create space")

    const creator = await testUtils.createUser("public-move-creator@example.com")
    await db.insert(schema.members).values([{ userId: creator.id, spaceId: space.id, role: "owner" }])

    const chat = await testUtils.createChat(space.id, "Public Thread", "thread", true, creator.id)
    if (!chat) throw new Error("Failed to create chat")

    await expect(moveThread({ chatId: chat.id, spaceId: null }, makeContext(creator.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })
  })

  test("rejects moving into a space when not all participants are members (v1 rule)", async () => {
    const space = await testUtils.createSpace("Member Rule Space")
    if (!space) throw new Error("Failed to create space")

    const creator = await testUtils.createUser("member-rule-creator@example.com")
    const outsider = await testUtils.createUser("member-rule-outsider@example.com")

    // Only creator is a space member.
    await db.insert(schema.members).values([{ userId: creator.id, spaceId: space.id, role: "member" }])

    const chat = await testUtils.createChat(null, "Home Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Failed to create chat")
    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, outsider.id)

    await expect(moveThread({ chatId: chat.id, spaceId: space.id }, makeContext(creator.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })
  })
})

