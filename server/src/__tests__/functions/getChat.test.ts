import { describe, expect, spyOn, test } from "bun:test"
import { getChat } from "@in/server/functions/messages.getChat"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { InputPeer, Peer } from "@inline-chat/protocol/core"

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

const makePeerUser = (userId: number): Peer => ({
  type: { oneofKind: "user", user: { userId: BigInt(userId) } },
})

describe("getChat", () => {
  setupTestLifecycle()

  test("a DM addressed by chat ID emits counterpart user peers in live and repair messages", async () => {
    const sender = (await testUtils.createUser("canonical-dm-sender@example.com"))!
    const recipient = (await testUtils.createUser("canonical-dm-recipient@example.com"))!
    const chat = (await testUtils.createPrivateChat(sender, recipient))!
    const rawPeer = makeInputPeerChat(chat.id)
    const pushes = spyOn(RealtimeUpdates, "pushToUser")
    try {
      const sent = await sendMessage(
        { peerId: rawPeer, message: "canonical peer" },
        testUtils.functionContext({ userId: sender.id, sessionId: 1 }),
      )
      const sentUpdate = sent.updates.find((update) => update.update.oneofKind === "newMessage")
      if (sentUpdate?.update.oneofKind !== "newMessage") throw new Error("Missing sender message update")
      const sentMessage = sentUpdate.update.newMessage.message
      if (!sentMessage) throw new Error("Missing sender message")
      const messageId = sentMessage.id
      expect(sentMessage.peerId).toEqual(makePeerUser(recipient.id))

      const recipientMessages = pushes.mock.calls
        .filter(([userId]) => userId === recipient.id)
        .flatMap(([, updates]) => updates)
        .filter((update) => update.update.oneofKind === "newMessage")
      expect(recipientMessages).toHaveLength(1)
      const recipientUpdate = recipientMessages[0]
      if (recipientUpdate?.update.oneofKind !== "newMessage") throw new Error("Missing recipient message update")
      expect(recipientUpdate.update.newMessage.message?.peerId).toEqual(makePeerUser(sender.id))

      const edited = await editMessage(
        { peer: rawPeer, messageId, text: "edited" },
        testUtils.functionContext({ userId: sender.id, sessionId: 1 }),
      )
      const editUpdate = edited.updates.find((update) => update.update.oneofKind === "editMessage")
      if (editUpdate?.update.oneofKind !== "editMessage") throw new Error("Missing edited message update")
      expect(editUpdate.update.editMessage.message?.peerId).toEqual(makePeerUser(recipient.id))

      const snapshot = await getChat(
        { peerId: rawPeer, includeRecentMessages: true },
        makeHandlerContext(sender.id),
      )
      expect(snapshot.chat.peerId).toEqual(makePeerUser(recipient.id))
      expect(snapshot.dialog?.peer).toEqual(makePeerUser(recipient.id))
      expect(snapshot.messages[0]?.peerId).toEqual(makePeerUser(recipient.id))
      const selected = await getMessages(
        { peerId: rawPeer, messageIds: [messageId] },
        makeHandlerContext(sender.id),
      )
      expect(selected.messages[0]?.peerId).toEqual(makePeerUser(recipient.id))
    } finally {
      pushes.mockRestore()
    }
  })

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

  test("concurrent first opens create one private chat with both dialogs", async () => {
    const userA = await testUtils.createUser("concurrent-first-open-a@example.com")
    const userB = await testUtils.createUser("concurrent-first-open-b@example.com")
    if (!userA || !userB) throw new Error("Users not created")

    const results = await Promise.all(
      Array.from({ length: 8 }, (_, index) =>
        index % 2 === 0
          ? getChat({ peerId: makeInputPeerUser(userB.id) }, makeHandlerContext(userA.id))
          : getChat({ peerId: makeInputPeerUser(userA.id) }, makeHandlerContext(userB.id)),
      ),
    )

    const storedChats = await db
      .select()
      .from(schema.chats)
      .where(
        and(
          eq(schema.chats.type, "private"),
          eq(schema.chats.minUserId, Math.min(userA.id, userB.id)),
          eq(schema.chats.maxUserId, Math.max(userA.id, userB.id)),
        ),
      )
    expect(storedChats).toHaveLength(1)

    const [storedChat] = storedChats
    if (!storedChat) throw new Error("Private chat not created")
    expect(results.every((result) => result.chat.id === BigInt(storedChat.id))).toBe(true)
    expect(results.every((result) => result.dialog !== undefined)).toBe(true)

    const storedDialogs = await db
      .select()
      .from(schema.dialogs)
      .where(eq(schema.dialogs.chatId, storedChat.id))
    expect(storedDialogs).toHaveLength(2)
    expect(new Set(storedDialogs.map((dialog) => dialog.userId))).toEqual(new Set([userA.id, userB.id]))
  })

  test("passes the DM peer profile photo to the user encoder", async () => {
    const currentUser = await testUtils.createUser("profile-photo-current@example.com")
    const peerUser = await testUtils.createUser("profile-photo-peer@example.com")
    if (!currentUser || !peerUser) throw new Error("Users not created")

    const fileUniqueId = `get-chat-profile-photo-${peerUser.id}`
    const [photo] = await db
      .insert(schema.files)
      .values({
        fileUniqueId,
        userId: peerUser.id,
        fileType: "photo",
        mimeType: "image/jpeg",
        fileSize: 123,
      })
      .returning()
    if (!photo) throw new Error("Profile photo not created")
    await db.update(schema.users).set({ photoFileId: photo.id }).where(eq(schema.users.id, peerUser.id))

    const userEncoderSpy = spyOn(Encoders, "user")
    const result = await getChat(
      { peerId: makeInputPeerUser(peerUser.id) },
      makeHandlerContext(currentUser.id),
    )

    const encodedPeerPhoto = userEncoderSpy.mock.calls.some(
      ([input]) => input.user.id === peerUser.id && input.photoFile?.fileUniqueId === fileUniqueId,
    )
    userEncoderSpy.mockRestore()

    expect(result.user?.id).toBe(BigInt(peerUser.id))
    expect(encodedPeerPhoto).toBe(true)
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
