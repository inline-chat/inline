import { describe, expect, test } from "bun:test"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { removeChatParticipant } from "@in/server/functions/messages.removeChatParticipant"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"

const makeFunctionContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
})

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

    expect(Number(added.userId)).toBe(target.id)

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
