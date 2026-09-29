import { beforeEach, describe, expect, test } from "bun:test"
import { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chatParticipants, chats, files, members, messages, voices } from "@in/server/db/schema"
import type { DbUser } from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { forwardMessages } from "@in/server/functions/messages.forwardMessages"
import { RealtimeRpcError } from "@in/server/realtime/errors"
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

  test("preserves structural rich content", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })
    await editMessage(
      {
        peer: scenario.fromPeerId,
        messageId: scenario.sourceMessageId,
        text: "# Forwarded heading",
        parseMarkdown: true,
      },
      context,
    )

    await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [scenario.sourceMessageId],
      },
      context,
    )

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.text).toBe("# Forwarded heading")
    expect(forwarded.blockContent?.blocks[0]?.kind.oneofKind).toBe("heading")
  })

  test("returns one destination ID per source occurrence in request order", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: false })
    await testUtils.createTestMessage({
      messageId: 2,
      chatId: scenario.sourceChatId,
      fromId: scenario.dmPeerUser.id,
      text: "second source message",
    })

    const result = await forwardMessages({
      fromPeerId: scenario.fromPeerId,
      toPeerId: scenario.toPeerId,
      messageIds: [2n, scenario.sourceMessageId, 2n],
    }, testUtils.functionContext({ userId: scenario.currentUser.id }))

    const returnedUpdateIds = result.updates.flatMap((update) =>
      update.update.oneofKind === "updateMessageId" ? [Number(update.update.updateMessageId.messageId)] : [],
    )
    expect(returnedUpdateIds).toEqual(result.messageIds)
    expect(new Set(result.messageIds).size).toBe(3)
    const forwarded = await Promise.all(result.messageIds.map((id) => MessageModel.getMessage(id, scenario.destinationThreadId)))
    expect(forwarded.map((message) => message.text)).toEqual(["second source message", "forward me", "second source message"])
    expect(forwarded.map((message) => message.fwdFromMessageId)).toEqual([2, 1, 2])
  })

  test("retains the delivered prefix when a later source message is missing", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: false })

    await expect(forwardMessages({
      fromPeerId: scenario.fromPeerId,
      toPeerId: scenario.toPeerId,
      messageIds: [scenario.sourceMessageId, 999_999n],
    }, testUtils.functionContext({ userId: scenario.currentUser.id })))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.MESSAGE_ID_INVALID })

    const forwarded = await MessageModel.getMessagesByIds(scenario.destinationThreadId, [1n, 2n])
    expect(forwarded).toHaveLength(1)
    expect(forwarded[0]?.text).toBe("forward me")
    expect(forwarded[0]?.fwdFromMessageId).toBe(Number(scenario.sourceMessageId))
  })

  test("rejects an inaccessible destination before forwarding any source message", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: false })
    await db.delete(chatParticipants).where(eq(chatParticipants.userId, scenario.currentUser.id))

    await expect(forwardMessages({
      fromPeerId: scenario.fromPeerId,
      toPeerId: scenario.toPeerId,
      messageIds: [scenario.sourceMessageId],
    }, testUtils.functionContext({ userId: scenario.currentUser.id })))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })

    const forwarded = await db.select().from(messages).where(eq(messages.chatId, scenario.destinationThreadId))
    expect(forwarded).toEqual([])
  })
})
