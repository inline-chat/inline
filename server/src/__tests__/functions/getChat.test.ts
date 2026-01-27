import { describe, expect, test } from "bun:test"
import { getChat } from "@in/server/functions/messages.getChat"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { InputPeer } from "@in/protocol/core"

const makeHandlerContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
  ip: "127.0.0.1",
})

const makeInputPeerChat = (chatId: number): InputPeer => ({
  type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } },
})

describe("getChat", () => {
  setupTestLifecycle()

  test("returns home thread for participant and creates dialog", async () => {
    const creator = await testUtils.createUser("home-chat-owner@example.com")
    const participant = await testUtils.createUser("home-chat-participant@example.com")
    if (!creator || !participant) throw new Error("Users not created")

    const chat = await testUtils.createChat(null, "Home Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")

    await testUtils.addParticipant(chat.id, creator.id)
    await testUtils.addParticipant(chat.id, participant.id)

    const result = await getChat({ peerId: makeInputPeerChat(chat.id) }, makeHandlerContext(creator.id))

    expect(result.chat.spaceId).toBeUndefined()
    expect(result.dialog.spaceId).toBeUndefined()

    const [dialog] = await db
      .select()
      .from(schema.dialogs)
      .where(eq(schema.dialogs.chatId, chat.id))

    expect(dialog?.userId).toBe(creator.id)
    expect(dialog?.spaceId).toBeNull()
  })

  test("rejects home thread for non-participant", async () => {
    const creator = await testUtils.createUser("home-chat-owner2@example.com")
    const outsider = await testUtils.createUser("home-chat-outsider@example.com")
    if (!creator || !outsider) throw new Error("Users not created")

    const chat = await testUtils.createChat(null, "Home Thread", "thread", false, creator.id)
    if (!chat) throw new Error("Chat not created")

    await testUtils.addParticipant(chat.id, creator.id)

    await expect(getChat({ peerId: makeInputPeerChat(chat.id) }, makeHandlerContext(outsider.id))).rejects.toMatchObject({
      code: RealtimeRpcError.Code.CHAT_ID_INVALID,
    })
  })
})
