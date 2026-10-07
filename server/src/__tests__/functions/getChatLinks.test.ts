import { describe, expect, test } from "bun:test"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { dialogs, users } from "@in/server/db/schema"
import { getChat } from "@in/server/functions/messages.getChat"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const chatPeer = (chatId: number): InputPeer => ({
  type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } },
})

const userPeer = (userId: number): InputPeer => ({
  type: { oneofKind: "user", user: { userId: BigInt(userId) } },
})

describe("getChat links", () => {
  setupTestLifecycle()

  test.each([false, true])("chat-ID DM lookup includes the canonical peer profile (bot=%s)", async (isBot) => {
    const viewer = await testUtils.createUser("link-viewer@example.com")
    const counterpart = await testUtils.createUser("link-counterpart@example.com")
    await db.update(users).set({ bot: isBot, timeZone: "Asia/Tokyo", shareTimeZone: false })
      .where(eq(users.id, counterpart.id))
    const chat = await testUtils.createPrivateChat(viewer, counterpart)
    if (!chat) throw new Error("DM fixture missing")

    // No existing dialog/profile projection is required for a chat-table link.
    const byChat = await getChat(
      { peerId: chatPeer(chat.id) },
      testUtils.functionContext({ userId: viewer.id }),
    )
    const byUser = await getChat(
      { peerId: userPeer(counterpart.id) },
      testUtils.functionContext({ userId: viewer.id }),
    )
    expect(byChat.chat.peerId).toEqual(byUser.chat.peerId)
    expect(byChat.dialog?.peer).toEqual(byUser.dialog?.peer)
    expect(byChat.user?.id).toBe(BigInt(counterpart.id))
    expect(byChat.user).toEqual(byUser.user)
    expect(byChat.user?.bot).toBe(isBot ? true : undefined)
    expect(byChat.user?.timeZone).toBeUndefined()

    const sent = await sendMessage(
      { peerId: userPeer(counterpart.id), message: "linked target" },
      testUtils.functionContext({ userId: viewer.id }),
    )
    const update = sent.updates.find((update) => update.update.oneofKind === "newMessage")
    if (update?.update.oneofKind !== "newMessage" || !update.update.newMessage.message) {
      throw new Error("Target message missing")
    }
    const target = update.update.newMessage.message
    const snapshot = await getChat(
      { peerId: chatPeer(chat.id), includeRecentMessages: true },
      testUtils.functionContext({ userId: viewer.id }),
    )
    expect(snapshot.messages.map((message) => [message.id, message.chatId, message.peerId])).toEqual([
      [target.id, BigInt(chat.id), byChat.chat.peerId],
    ])
    const selected = await getMessages(
      { peerId: userPeer(counterpart.id), messageIds: [target.id] },
      testUtils.functionContext({ userId: viewer.id }),
    )
    expect(selected.messages[0]?.id).toBe(target.id)
    expect(selected.messages[0]?.chatId).toBe(BigInt(chat.id))
    expect(selected.messages[0]?.peerId).toEqual(byChat.chat.peerId)

    const reverse = await getChat(
      { peerId: chatPeer(chat.id), includeRecentMessages: true },
      testUtils.functionContext({ userId: counterpart.id }),
    )
    expect(reverse.user?.id).toBe(BigInt(viewer.id))
    expect(reverse.messages[0]?.id).toBe(target.id)
    expect(reverse.messages[0]?.chatId).toBe(BigInt(chat.id))
    expect(reverse.messages[0]?.peerId).toEqual(reverse.chat.peerId)
  })

  test("a chat-ID DM link denies outsiders without creating their dialog", async () => {
    const viewer = await testUtils.createUser("link-private-viewer@example.com")
    const counterpart = await testUtils.createUser("link-private-peer@example.com")
    const outsider = await testUtils.createUser("link-outsider@example.com")
    const chat = await testUtils.createPrivateChat(viewer, counterpart)
    if (!chat) throw new Error("DM fixture missing")

    await expect(getChat(
      { peerId: chatPeer(chat.id) },
      testUtils.functionContext({ userId: outsider.id }),
    )).rejects.toMatchObject({ code: RealtimeRpcError.Code.CHAT_ID_INVALID })
    const outsiderDialogs = await db.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, outsider.id)))
    expect(outsiderDialogs).toHaveLength(0)
  })

  test("group links do not add a peer profile to the response", async () => {
    const viewer = await testUtils.createUser("link-group-viewer@example.com")
    const chat = await testUtils.createChat(null, "Linked Group", "thread", false, viewer.id)
    if (!chat) throw new Error("Group fixture missing")
    await testUtils.addParticipant(chat.id, viewer.id)

    const result = await getChat(
      { peerId: chatPeer(chat.id) },
      testUtils.functionContext({ userId: viewer.id }),
    )
    expect(result.user).toBeUndefined()
    expect(result.chat.peerId?.type.oneofKind).toBe("chat")
  })
})
