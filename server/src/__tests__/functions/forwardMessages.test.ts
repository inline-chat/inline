import { beforeEach, describe, expect, test } from "bun:test"
import { InputPeer, type RichMessage } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import {
  chatParticipants,
  chats,
  files,
  members,
  messageRichMedia,
  messages,
  photos,
  photoSizes,
  voices,
} from "@in/server/db/schema"
import type { DbUser } from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { forwardMessages } from "@in/server/functions/messages.forwardMessages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const runId = Date.now()
let userIndex = 0
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

setupTestLifecycle()

type Scenario = {
  currentUser: DbUser
  dmPeerUser: DbUser
  sourceChatId: number
  destinationThreadId: number
  sourceMessageId: bigint
  fromPeerId: InputPeer
  toPeerId: InputPeer
}

const createScenario = async ({ sourceFromCurrentUser }: { sourceFromCurrentUser: boolean }): Promise<Scenario> => {
  const currentUser = await testUtils.createUser(nextEmail("current"))
  const dmPeerUser = await testUtils.createUser(nextEmail("dm-peer"))
  const destinationPeerUser = await testUtils.createUser(nextEmail("thread-peer"))
  const space = await testUtils.createSpace("Forward Test Space")
  if (!space) {
    throw new Error("Failed to create test space")
  }

  await db.insert(members).values([
    { userId: currentUser.id, spaceId: space.id, role: "member" },
    { userId: destinationPeerUser.id, spaceId: space.id, role: "member" },
  ])

  const [destinationThread] = await db
    .insert(chats)
    .values({
      type: "thread",
      title: "Private Thread",
      spaceId: space.id,
      publicThread: false,
      createdBy: currentUser.id,
    })
    .returning()
  if (!destinationThread) {
    throw new Error("Failed to create destination thread")
  }

  await db.insert(chatParticipants).values([
    { chatId: destinationThread.id, userId: currentUser.id },
    { chatId: destinationThread.id, userId: destinationPeerUser.id },
  ])

  const sourceDm = await testUtils.createPrivateChat(currentUser, dmPeerUser)
  if (!sourceDm) {
    throw new Error("Failed to create source DM")
  }

  const sourceMessage = await testUtils.createTestMessage({
    messageId: 1,
    chatId: sourceDm.id,
    fromId: sourceFromCurrentUser ? currentUser.id : dmPeerUser.id,
    text: "forward me",
  })

  return {
    currentUser,
    dmPeerUser,
    sourceChatId: sourceDm.id,
    destinationThreadId: destinationThread.id,
    sourceMessageId: BigInt(sourceMessage.messageId),
    fromPeerId: {
      type: { oneofKind: "user", user: { userId: BigInt(dmPeerUser.id) } },
    },
    toPeerId: {
      type: { oneofKind: "chat", chat: { chatId: BigInt(destinationThread.id) } },
    },
  }
}

const forwardedMessageFromDestination = async (destinationThreadId: number) => {
  const [storedMessage] = await db
    .select()
    .from(messages)
    .where(eq(messages.chatId, destinationThreadId))

  if (!storedMessage) {
    throw new Error("Expected forwarded message to be stored")
  }

  return MessageModel.getMessage(storedMessage.messageId, destinationThreadId)
}

const createVoiceForUser = async (userId: number) => {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `INV-forward-${runId}-${userIndex++}`,
      userId,
      fileType: "voice",
      mimeType: "audio/ogg",
      fileSize: 222,
    })
    .returning()

  if (!file) {
    throw new Error("Failed to create test voice file")
  }

  const [voice] = await db
    .insert(voices)
    .values({
      fileId: file.id,
      duration: 9,
      waveform: Buffer.from([8, 6, 7, 5]),
    })
    .returning()

  if (!voice) {
    throw new Error("Failed to create test voice")
  }

  return voice
}

const createPhotoForUser = async (userId: number) => {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `INP-forward-${runId}-${userIndex++}`,
      userId,
      fileType: "photo",
      mimeType: "image/jpeg",
      fileSize: 1234,
      width: 320,
      height: 180,
    })
    .returning()

  const [photo] = await db
    .insert(photos)
    .values({
      format: "jpeg",
      width: 320,
      height: 180,
    })
    .returning()

  if (!file || !photo) {
    throw new Error("Failed to create test photo")
  }

  await db.insert(photoSizes).values({
    fileId: file.id,
    photoId: photo.id,
    size: "f",
    width: 320,
    height: 180,
  })

  return photo
}

const richPhotoMessage = (photoId: number): RichMessage => ({
  version: 1,
  fallbackText: "Embedded rich photo",
  blocks: [
    {
      blockId: "rich-photo",
      block: {
        oneofKind: "photo",
        photo: {
          media: {
            alt: "Forwarded embedded photo",
            width: 320,
            height: 180,
            media: { oneofKind: "photoId", photoId: BigInt(photoId) },
          },
          caption: [
            {
              text: "Forwarded rich photo caption",
              children: [],
              styles: [],
            },
          ],
        },
      },
    },
  ],
})

describe("forwardMessages DM -> private thread", () => {
  beforeEach(() => {
    userIndex = 0
  })

  test("forwards incoming DM message to a private thread", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: false })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })

    const result = await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [scenario.sourceMessageId],
      },
      context,
    )

    expect(result.updates.length).toBeGreaterThan(0)

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.text).toBe("forward me")
    expect(forwarded.fwdFromPeerUserId).toBe(scenario.dmPeerUser.id)
    expect(forwarded.fwdFromSenderId).toBe(scenario.dmPeerUser.id)
    expect(forwarded.fwdFromMessageId).toBe(Number(scenario.sourceMessageId))
  })

  test("forwards outgoing DM message to a private thread", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })

    const result = await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [scenario.sourceMessageId],
      },
      context,
    )

    expect(result.updates.length).toBeGreaterThan(0)

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.text).toBe("forward me")
    expect(forwarded.fwdFromPeerUserId).toBeNull()
    expect(forwarded.fwdFromPeerChatId).toBeNull()
    expect(forwarded.fwdFromSenderId).toBeNull()
    expect(forwarded.fwdFromMessageId).toBeNull()
  })

  test("forwards voice media and clones the voice row", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: false })
    const voice = await createVoiceForUser(scenario.dmPeerUser.id)
    const [sourceVoiceMessage] = await db
      .insert(messages)
      .values({
        messageId: 2,
        chatId: scenario.sourceChatId,
        fromId: scenario.dmPeerUser.id,
        mediaType: "voice",
        voiceId: voice.id,
      })
      .returning()

    if (!sourceVoiceMessage) {
      throw new Error("Failed to create source voice message")
    }

    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })

    const result = await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [BigInt(sourceVoiceMessage.messageId)],
      },
      context,
    )

    expect(result.updates.length).toBeGreaterThan(0)

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.voiceId).not.toBeNull()
    expect(forwarded.voice?.id).not.toBe(voice.id)
    expect(forwarded.voice?.duration).toBe(9)
    expect(forwarded.voice?.waveform).toEqual(Buffer.from([8, 6, 7, 5]))
    expect(forwarded.fwdFromPeerUserId).toBe(scenario.dmPeerUser.id)
  })

  test("forwards embedded rich media without promoting it to a top-level attachment", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    await db.update(chats).set({ lastMsgId: 1 }).where(eq(chats.id, scenario.sourceChatId))

    const photo = await createPhotoForUser(scenario.currentUser.id)

    const richText = richPhotoMessage(photo.id)
    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })
    await sendMessage(
      {
        peerId: scenario.fromPeerId,
        message: richText.fallbackText,
        richText,
        skipLinkProcessing: true,
      },
      context,
    )

    const source = await MessageModel.getMessage(2, scenario.sourceChatId)
    expect(source.photoId).toBeNull()
    expect(source.richText?.blocks[0]?.block.oneofKind).toBe("photo")
    expect(source.text).toBe("[Image: Forwarded embedded photo] Forwarded rich photo caption")

    await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [2n],
      },
      context,
    )

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.text).toBe(source.text)
    expect(forwarded.photoId).toBeNull()
    expect(forwarded.mediaType).toBeNull()
    expect(forwarded.richText?.blocks[0]?.block.oneofKind).toBe("photo")

    if (forwarded.richText?.blocks[0]?.block.oneofKind !== "photo") {
      throw new Error("Expected forwarded rich photo block")
    }

    const media = forwarded.richText.blocks[0].block.photo.media?.media
    expect(media?.oneofKind).toBe("photoId")
    if (media?.oneofKind !== "photoId") {
      throw new Error("Expected forwarded rich photo media ref")
    }
    expect(media.photoId).not.toBe(BigInt(photo.id))

    const forwardedRichMediaRows = await db
      .select()
      .from(messageRichMedia)
      .where(eq(messageRichMedia.messageGlobalId, forwarded.globalId))

    expect(forwardedRichMediaRows).toHaveLength(1)
    expect(forwardedRichMediaRows[0]?.photoId).toBe(Number(media.photoId))
    expect(forwardedRichMediaRows[0]?.photoId).not.toBe(photo.id)
  })
})
