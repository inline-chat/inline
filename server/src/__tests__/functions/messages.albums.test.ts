import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { files, messages, photoSizes, photos, voices, type DbUser } from "@in/server/db/schema"
import { forwardMessages, forwardedAlbumIds } from "@in/server/functions/messages.forwardMessages"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { sendMessage as realtimeSendMessage } from "@in/server/realtime/handlers/messages.sendMessage"
import { messageNotificationBody } from "@in/server/modules/notifications/messagePreview"

const createUser = (label: string) => testUtils.createUser(`${label}-${crypto.randomUUID()}@example.com`)

const createPhoto = async (userId: number) => {
  const [file] = await db
    .insert(files)
    .values({ fileUniqueId: `photo-${crypto.randomUUID()}`, userId, fileType: "photo", fileSize: 128 })
    .returning()
  const [photo] = await db.insert(photos).values({ format: "jpeg", width: 64, height: 48 }).returning()
  if (!file || !photo) throw new Error("Failed to create test photo")
  await db.insert(photoSizes).values({ fileId: file.id, photoId: photo.id, size: "f", width: 64, height: 48 })
  return photo
}

const createVoice = async (userId: number) => {
  const [file] = await db
    .insert(files)
    .values({ fileUniqueId: `voice-${crypto.randomUUID()}`, userId, fileType: "voice", fileSize: 128 })
    .returning()
  const [voice] = await db
    .insert(voices)
    .values({ fileId: file!.id, duration: 2, waveform: Buffer.from([1, 2, 3]) })
    .returning()
  return voice!
}

const selfChat = async (user: DbUser) => {
  const chat = await testUtils.createPrivateChat(user, user)
  if (!chat) throw new Error("Failed to create self chat")
  const peerId: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
  return { chat, peerId }
}

const contextFor = (user: DbUser) => testUtils.functionContext({ userId: user.id, sessionId: 1 })

const newMessages = (updates: Update[]) =>
  updates.flatMap((update) => (update.update.oneofKind === "newMessage" ? [update.update.newMessage.message!] : []))

describe("message albums", () => {
  setupTestLifecycle()

  test("stores and encodes the album id on photos sent through the realtime handler", async () => {
    const user = await createUser("album-sender")
    const { chat, peerId } = await selfChat(user)
    const photo = await createPhoto(user.id)

    const result = await realtimeSendMessage(
      {
        peerId,
        randomId: 11n,
        groupedId: 9001n,
        media: { media: { oneofKind: "photo", photo: { photoId: BigInt(photo.id) } } },
      },
      { userId: user.id, sessionId: 1, connectionId: "albums", sendRaw: () => {}, sendRpcReply: () => {} },
    )

    const [stored] = await db.select().from(messages).where(eq(messages.chatId, chat.id))
    expect(stored?.groupedId).toBe(9001n)
    expect(newMessages(result.updates).map((message) => message.groupedId)).toEqual([9001n])
    const history = await getChatHistory({ peerId }, contextFor(user))
    expect(history.messages.map((message) => message.groupedId)).toEqual([9001n])
  })

  test("rejects an album id on text, voice and stickers, and treats zero as none", async () => {
    const user = await createUser("album-reject")
    const { chat, peerId } = await selfChat(user)
    const context = contextFor(user)
    const voice = await createVoice(user.id)

    await expect(sendMessage({ peerId, message: "hi", groupedId: 5n }, context)).rejects.toThrow()
    await expect(sendMessage({ peerId, voiceId: BigInt(voice.id), groupedId: 5n }, context)).rejects.toThrow()
    const sticker = await createPhoto(user.id)
    await expect(
      sendMessage({ peerId, photoId: BigInt(sticker.id), isSticker: true, groupedId: 5n }, context),
    ).rejects.toThrow()
    expect(await db.select().from(messages).where(eq(messages.chatId, chat.id))).toHaveLength(0)

    await sendMessage({ peerId, message: "plain", groupedId: 0n }, context)
    const [plain] = await db.select().from(messages).where(eq(messages.chatId, chat.id))
    expect(plain?.groupedId).toBeNull()
  })

  test("history pages never end inside an album", async () => {
    const user = await createUser("album-history")
    const other = await createUser("album-history-other")
    const { chat, peerId } = await selfChat(user)
    // 1..10, where 4..7 are one album from `user`; 8 is another sender with the same id (not the album).
    for (let messageId = 1; messageId <= 10; messageId++) {
      await testUtils.createTestMessage({
        messageId,
        chatId: chat.id,
        fromId: messageId === 8 ? other.id : user.id,
        text: `m${messageId}`,
      })
    }
    for (const messageId of [4, 5, 6, 7, 8]) {
      await db
        .update(messages)
        .set({ groupedId: 77n })
        .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, messageId)))
    }
    await db.update(messages).set({ mediaType: "photo" }).where(eq(messages.chatId, chat.id))
    const context = contextFor(user)
    const ids = (result: Awaited<ReturnType<typeof getChatHistory>>) => result.messages.map((m) => Number(m.id))

    // Latest page ends at 6, inside the album: 5 and 4 come with it.
    expect(ids(await getChatHistory({ peerId, limit: 5 }, context))).toEqual([10, 9, 8, 7, 6, 5, 4])
    // An older page ending exactly at the album's first message adds nothing.
    expect(ids(await getChatHistory({ peerId, beforeId: 6n, mode: "older", limit: 2 }, context))).toEqual([5, 4])
    // A newer page cut at 5 brings 6 and 7, but not 8 (another sender).
    expect(ids(await getChatHistory({ peerId, afterId: 3n, mode: "newer", limit: 2 }, context))).toEqual([7, 6, 5, 4])
    // Around completes both edges.
    expect(
      ids(
        await getChatHistory(
          { peerId, anchorId: 6n, mode: "around", beforeLimit: 0, afterLimit: 0, includeAnchor: true },
          context,
        ),
      ),
    ).toEqual([7, 6, 5, 4])
    // A page not touching an album is unchanged.
    expect(ids(await getChatHistory({ peerId, beforeId: 4n, mode: "older", limit: 2 }, context))).toEqual([3, 2])
  })

  test("only the first message of an album has no earlier member", async () => {
    const user = await createUser("album-notify")
    const { chat, peerId } = await selfChat(user)
    const context = contextFor(user)
    for (let index = 0; index < 3; index++) {
      const photo = await createPhoto(user.id)
      await sendMessage({ peerId, photoId: BigInt(photo.id), groupedId: 42n }, context)
    }
    const photo = await createPhoto(user.id)
    await sendMessage({ peerId, photoId: BigInt(photo.id), groupedId: 43n }, context)

    const earlier = async (messageId: number, groupedId: bigint) =>
      MessageModel.hasEarlierAlbumMessage({ chatId: chat.id, messageId, fromId: user.id, groupedId })
    expect(await earlier(1, 42n)).toBe(false)
    expect(await earlier(2, 42n)).toBe(true)
    expect(await earlier(3, 42n)).toBe(true)
    expect(await earlier(4, 43n)).toBe(false)
  })

  test("forwarding album members together keeps them one album under a new id", async () => {
    const user = await createUser("album-forward")
    const source = await selfChat(user)
    const context = contextFor(user)
    for (let index = 0; index < 3; index++) {
      const photo = await createPhoto(user.id)
      await sendMessage(
        { peerId: source.peerId, photoId: BigInt(photo.id), groupedId: 500n, message: index === 0 ? "trip" : undefined },
        context,
      )
    }
    const destination = await testUtils.createChat(null, "Album destination", "thread", false, user.id)
    await testUtils.addParticipant(destination!.id, user.id)
    const toPeerId: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(destination!.id) } } }

    await forwardMessages(
      { fromPeerId: source.peerId, toPeerId, messageIds: [1n, 2n, 3n], shareForwardHeader: true },
      context,
    )
    await forwardMessages({ fromPeerId: source.peerId, toPeerId, messageIds: [2n], shareForwardHeader: true }, context)

    const forwarded = await db
      .select()
      .from(messages)
      .where(eq(messages.chatId, destination!.id))
      .orderBy(messages.messageId)
    expect(forwarded).toHaveLength(4)
    const albumIds = new Set(forwarded.slice(0, 3).map((message) => message.groupedId))
    expect(albumIds.size).toBe(1)
    expect([...albumIds][0]).not.toBeNull()
    expect([...albumIds][0]).not.toBe(500n)
    expect(forwarded[3]?.groupedId).toBeNull()
  })

  test("forwardedAlbumIds groups by sender and source album, skipping lone members", () => {
    let next = 100n
    const ids = forwardedAlbumIds(
      [
        { messageId: 1, fromId: 1, groupedId: 7n },
        { messageId: 2, fromId: 1, groupedId: 7n },
        { messageId: 3, fromId: 2, groupedId: 7n },
        { messageId: 4, fromId: 1, groupedId: null },
        { messageId: 5, fromId: 1, groupedId: 8n },
        { messageId: 6, fromId: 1, groupedId: 8n },
      ],
      () => next++,
    )
    expect([...ids.entries()]).toEqual([
      [1, 100n],
      [2, 100n],
      [5, 101n],
      [6, 101n],
    ])
  })

  test("an album's notification says Album unless it has a caption", () => {
    expect(messageNotificationBody({ mediaType: "photo", isAlbum: true })).toBe("🖼️ Album")
    expect(messageNotificationBody({ mediaType: "video", isAlbum: true })).toBe("🖼️ Album")
    expect(messageNotificationBody({ mediaType: "document", isAlbum: true })).toBe("📄 Files")
    expect(messageNotificationBody({ mediaType: "photo", isAlbum: true, messageText: "Trip" })).toBe(
      messageNotificationBody({ mediaType: "photo", messageText: "Trip" }),
    )
  })
})
