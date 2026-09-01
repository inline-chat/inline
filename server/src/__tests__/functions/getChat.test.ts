import { describe, expect, test } from "bun:test"
import { getChat } from "@in/server/functions/messages.getChat"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { InputPeer } from "@inline-chat/protocol/core"

const makeHandlerContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
  ip: "127.0.0.1",
})

const makeInputPeerChat = (chatId: number): InputPeer => ({
  type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } },
})

const makeInputPeerUser = (userId: number): InputPeer => ({
  type: { oneofKind: "user", user: { userId: BigInt(userId) } },
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
    const resultDialog = result.dialog

    expect(result.chat.spaceId).toBeUndefined()
    expect(resultDialog).toBeDefined()
    expect(resultDialog!.spaceId).toBeUndefined()

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
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })
  })

  test("returns one dialog when concurrent requests open the same existing DM", async () => {
    const currentUser = await testUtils.createUser("concurrent-dialog-current@example.com")
    const peerUser = await testUtils.createUser("concurrent-dialog-peer@example.com")
    if (!currentUser || !peerUser) throw new Error("Users not created")

    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: currentUser,
      userB: peerUser,
      createDialogForUserA: false,
      createDialogForUserB: false,
    })

    const results = await Promise.all(
      Array.from({ length: 8 }, () =>
        getChat(
          { peerId: makeInputPeerUser(peerUser.id) },
          makeHandlerContext(currentUser.id),
        ),
      ),
    )
    expect(results.every((result) => result.dialog !== undefined)).toBe(true)

    const storedDialogs = await db
      .select()
      .from(schema.dialogs)
      .where(
        and(
          eq(schema.dialogs.chatId, chat.id),
          eq(schema.dialogs.userId, currentUser.id),
        ),
      )
    expect(storedDialogs).toHaveLength(1)
  })

  test("returns the optional newest repair window with the existing unread semantics", async () => {
    const viewer = await testUtils.createUser("repair-window-viewer@example.com")
    const sender = await testUtils.createUser("repair-window-sender@example.com")
    const chat = await testUtils.createChat(null, "Repair Window", "thread", false, viewer.id)
    if (!viewer || !sender || !chat) throw new Error("Repair fixture not created")

    await testUtils.addParticipant(chat.id, viewer.id)
    await db.insert(schema.dialogs).values({
      chatId: chat.id,
      userId: viewer.id,
      readInboxMaxId: 97,
    })
    await db.insert(schema.messages).values(
      Array.from({ length: 101 }, (_, index) => ({
        chatId: chat.id,
        messageId: index + 1,
        fromId: index === 100 ? viewer.id : sender.id,
        countsAsUnread: index !== 99,
        text: `message ${index + 1}`,
      })),
    )
    await db.update(schema.chats).set({ lastMsgId: 101, updateSeq: 7 }).where(eq(schema.chats.id, chat.id))

    const metadataOnly = await getChat(
      { peerId: makeInputPeerChat(chat.id) },
      makeHandlerContext(viewer.id),
    )
    expect(metadataOnly.messages).toEqual([])

    const repair = await getChat(
      { peerId: makeInputPeerChat(chat.id), includeRecentMessages: true },
      makeHandlerContext(viewer.id),
    )
    expect(repair.chat.seq).toBe(7)
    expect(repair.chat.lastMsgId).toBe(101n)
    expect(repair.dialog?.readMaxId).toBe(97n)
    expect(repair.dialog?.unreadCount).toBe(2)
    expect(repair.messages).toHaveLength(100)
    expect(repair.messages[0]?.id).toBe(101n)
    expect(repair.messages.at(-1)?.id).toBe(2n)
  })
})
