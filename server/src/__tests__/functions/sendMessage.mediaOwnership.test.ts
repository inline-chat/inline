import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { RpcError_Code, type InputPeer } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import {
  documents,
  files,
  messages,
  photoSizes,
  photos,
  videos,
  voices,
  type DbUser,
} from "@in/server/db/schema"
import { forwardMessages } from "@in/server/functions/messages.forwardMessages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { sendMessage as realtimeSendMessage } from "@in/server/realtime/handlers/messages.sendMessage"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import { InlineError } from "@in/server/types/errors"

const createUser = (label: string) => testUtils.createUser(`${label}-${crypto.randomUUID()}@example.com`)

const createFile = async (userId: number, fileType: "photo" | "video" | "document" | "voice") => {
  const [file] = await db
    .insert(files)
    .values({ fileUniqueId: `${fileType}-${crypto.randomUUID()}`, userId, fileType, fileSize: 128 })
    .returning()
  if (!file) throw new Error("Failed to create test file")
  return file
}

const createPhoto = async (userId: number) => {
  const file = await createFile(userId, "photo")
  const [photo] = await db.insert(photos).values({ format: "jpeg", width: 64, height: 64 }).returning()
  if (!photo) throw new Error("Failed to create test photo")
  await db.insert(photoSizes).values({ fileId: file.id, photoId: photo.id, size: "f", width: 64, height: 64 })
  return photo
}

const createVideo = async (userId: number, thumbnailPhotoId?: number) => {
  const file = await createFile(userId, "video")
  const [video] = await db
    .insert(videos)
    .values({
      fileId: file.id,
      photoId: thumbnailPhotoId === undefined ? null : BigInt(thumbnailPhotoId),
      width: 64,
      height: 64,
      duration: 3,
    })
    .returning()
  if (!video) throw new Error("Failed to create test video")
  return video
}

const createDocument = async (userId: number, thumbnailPhotoId?: number) => {
  const file = await createFile(userId, "document")
  const [document] = await db
    .insert(documents)
    .values({ fileId: file.id, photoId: thumbnailPhotoId === undefined ? null : BigInt(thumbnailPhotoId) })
    .returning()
  if (!document) throw new Error("Failed to create test document")
  return document
}

const createVoice = async (userId: number) => {
  const file = await createFile(userId, "voice")
  const [voice] = await db
    .insert(voices)
    .values({ fileId: file.id, duration: 2, waveform: Buffer.from([1, 2, 3]) })
    .returning()
  if (!voice) throw new Error("Failed to create test voice")
  return voice
}

const selfChatPeer = async (user: DbUser): Promise<InputPeer> => {
  const chat = await testUtils.createPrivateChat(user, user)
  if (!chat) throw new Error("Failed to create self chat")
  return { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
}

const contextFor = (user: DbUser) => testUtils.functionContext({ userId: user.id, sessionId: 1 })

const MEDIA_NOT_OWNED = { type: "MEDIA_NOT_OWNED", code: 400, description: InlineError.ApiError.MEDIA_NOT_OWNED[2] }

const ownersOf = async (fileIds: number[]) =>
  (await Promise.all(fileIds.map((id) => db.select({ userId: files.userId }).from(files).where(eq(files.id, id)))))
    .flat()
    .map((row) => row.userId)

describe("sendMessage media ownership", () => {
  setupTestLifecycle()

  test("rejects another user's media ids exactly like missing ids", async () => {
    const victim = await createUser("media-victim")
    const attacker = await createUser("media-attacker")
    const peerId = await selfChatPeer(attacker)
    const context = contextFor(attacker)
    const photo = await createPhoto(victim.id)
    const video = await createVideo(victim.id)
    const document = await createDocument(victim.id)
    const voice = await createVoice(victim.id)

    await expect(sendMessage({ peerId, photoId: BigInt(photo.id) }, context)).rejects.toMatchObject(MEDIA_NOT_OWNED)
    await expect(sendMessage({ peerId, videoId: BigInt(video.id) }, context)).rejects.toMatchObject(MEDIA_NOT_OWNED)
    await expect(sendMessage({ peerId, documentId: BigInt(document.id) }, context)).rejects.toMatchObject(
      MEDIA_NOT_OWNED,
    )
    await expect(sendMessage({ peerId, voiceId: BigInt(voice.id) }, context)).rejects.toMatchObject(MEDIA_NOT_OWNED)
    await expect(sendMessage({ peerId, photoId: BigInt(photo.id + 1_000_000) }, context)).rejects.toMatchObject(
      MEDIA_NOT_OWNED,
    )

    expect(await db.select().from(messages).where(eq(messages.fromId, attacker.id))).toHaveLength(0)
  })

  test("rejects the sender's own media when its thumbnail is another user's photo", async () => {
    const victim = await createUser("thumb-victim")
    const attacker = await createUser("thumb-attacker")
    const peerId = await selfChatPeer(attacker)
    const context = contextFor(attacker)
    const victimPhoto = await createPhoto(victim.id)
    const video = await createVideo(attacker.id, victimPhoto.id)
    const document = await createDocument(attacker.id, victimPhoto.id)

    await expect(sendMessage({ peerId, videoId: BigInt(video.id) }, context)).rejects.toMatchObject(MEDIA_NOT_OWNED)
    await expect(sendMessage({ peerId, documentId: BigInt(document.id) }, context)).rejects.toMatchObject(
      MEDIA_NOT_OWNED,
    )
  })

  test("lets owners send their own media, including thumbnails", async () => {
    const owner = await createUser("media-owner")
    const peerId = await selfChatPeer(owner)
    const context = contextFor(owner)
    const photo = await createPhoto(owner.id)
    const video = await createVideo(owner.id, (await createPhoto(owner.id)).id)
    const document = await createDocument(owner.id, (await createPhoto(owner.id)).id)
    const voice = await createVoice(owner.id)

    await sendMessage({ peerId, photoId: BigInt(photo.id) }, context)
    await sendMessage({ peerId, videoId: BigInt(video.id) }, context)
    await sendMessage({ peerId, documentId: BigInt(document.id) }, context)
    await sendMessage({ peerId, voiceId: BigInt(voice.id) }, context)

    const sent = await db.select().from(messages).where(eq(messages.fromId, owner.id))
    expect(sent.map((message) => message.mediaType).sort()).toEqual(["document", "photo", "video", "voice"])
  })

  test("reuses media from a visible message only by forwarding, which copies it to the forwarder", async () => {
    const author = await createUser("shared-author")
    const viewer = await createUser("shared-viewer")
    const chat = await testUtils.createChat(null, "Shared media", "thread", false, author.id)
    if (!chat) throw new Error("Failed to create shared chat")
    await testUtils.addParticipant(chat.id, author.id)
    await testUtils.addParticipant(chat.id, viewer.id)
    const sharedPeer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
    const document = await createDocument(author.id, (await createPhoto(author.id)).id)
    await sendMessage({ peerId: sharedPeer, documentId: BigInt(document.id) }, contextFor(author))

    const viewerPeer = await selfChatPeer(viewer)
    const viewerContext = contextFor(viewer)
    await expect(sendMessage({ peerId: viewerPeer, documentId: BigInt(document.id) }, viewerContext)).rejects.toMatchObject(
      MEDIA_NOT_OWNED,
    )

    for (const shareForwardHeader of [true, false]) {
      const { messageIds } = await forwardMessages(
        { fromPeerId: sharedPeer, toPeerId: viewerPeer, messageIds: [1n], shareForwardHeader },
        viewerContext,
      )
      const viewerChatId = Number(viewerPeer.type.oneofKind === "chat" ? viewerPeer.type.chat.chatId : 0)
      const forwarded = await MessageModel.getMessage(messageIds[0]!, viewerChatId)
      expect(forwarded.fwdFromMessageId !== null).toBe(shareForwardHeader)
      const [copied] = await db.select().from(documents).where(eq(documents.id, forwarded.documentId!))
      const thumbnailFiles = await db.select().from(photoSizes).where(eq(photoSizes.photoId, Number(copied!.photoId)))
      expect(await ownersOf([copied!.fileId!, ...thumbnailFiles.map((size) => size.fileId!)])).toEqual([
        viewer.id,
        viewer.id,
      ])
    }
  })

  test("reports MEDIA_NOT_OWNED as a realtime RPC error", async () => {
    const victim = await createUser("rpc-victim")
    const attacker = await createUser("rpc-attacker")
    const peerId = await selfChatPeer(attacker)
    const photo = await createPhoto(victim.id)

    const error = await realtimeSendMessage(
      { peerId, randomId: 1n, media: { media: { oneofKind: "photo", photo: { photoId: BigInt(photo.id) } } } },
      {
        userId: attacker.id,
        sessionId: 1,
        connectionId: "media-ownership-test",
        sendRaw: () => {},
        sendRpcReply: () => {},
      },
    ).then(
      () => undefined,
      (failure: unknown) => toRealtimeRpcError(failure),
    )

    expect(error).toMatchObject({
      code: RpcError_Code.MEDIA_NOT_OWNED,
      codeNumber: 400,
      message: InlineError.ApiError.MEDIA_NOT_OWNED[2],
    })
  })
})
