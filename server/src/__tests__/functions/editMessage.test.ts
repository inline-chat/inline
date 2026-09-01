import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import {
  InputPeer,
  BlockTable_Alignment,
  Message,
  MessageEntity_Type,
  Photo_Format,
  type EditMessageResult,
} from "@inline-chat/protocol/core"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import {
  blockContentImageJobs,
  blockContents,
  files,
  messages,
  photos,
  threadGraphLinks,
  users,
  voices,
} from "@in/server/db/schema"
import { and, eq, isNull } from "drizzle-orm"
import { replaceMessageThreadLinks } from "@in/server/modules/threadGraph/links"
import { getOutlinks } from "@in/server/modules/threadGraph/queries"
import { publishClaimedBlockImageJobForTests } from "@in/server/modules/message/blockContentImageWorker"
import { decryptStoredBlockContent, encryptStoredBlockContent } from "@in/server/modules/message/blockContentPayload"

let currentUser: DbUser
let privateChat: DbChat
let privateChatPeerId: InputPeer
let context: FunctionContext
let userIndex = 0

const runId = Date.now()
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

function extractEditedMessage(result: EditMessageResult): Message | null {
  const update = result.updates[0]
  if (update?.update.oneofKind !== "editMessage") {
    return null
  }
  return update.update.editMessage?.message ?? null
}

function extractSentMessageId(result: Awaited<ReturnType<typeof sendMessage>>): bigint | undefined {
  return result.updates[0]?.update.oneofKind === "updateMessageId"
    ? result.updates[0].update.updateMessageId?.messageId
    : undefined
}

async function createVoiceForUser(userId: number) {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `EDIT-VOICE-${runId}-${userIndex++}`,
      userId,
      fileType: "voice",
      mimeType: "audio/ogg",
      fileSize: 321,
    })
    .returning()

  if (!file) {
    throw new Error("Failed to create test voice file")
  }

  const [voice] = await db
    .insert(voices)
    .values({
      fileId: file.id,
      duration: 8,
      waveform: Buffer.from([1, 2, 3]),
    })
    .returning()

  if (!voice) {
    throw new Error("Failed to create test voice")
  }

  return voice
}

describe("editMessage function", () => {
  beforeAll(async () => {
    await setupTestDatabase()
    currentUser = (await testUtils.createUser(nextEmail("edit-user")))!
    privateChat = (await testUtils.createPrivateChat(currentUser, currentUser))!
    privateChatPeerId = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(privateChat.id) } },
    }
    context = testUtils.functionContext({ userId: currentUser.id, sessionId: 1 })
  })
  afterAll(teardownTestDatabase)

  test("edits one message to a 90k rich progress payload", async () => {
    const sent = await sendMessage({
      peerId: privateChatPeerId,
      message: "Working",
    }, context)
    const messageId = extractSentMessageId(sent)
    if (!messageId) throw new Error("message was not created")
    const source = [
      "<details open>",
      "<summary kind=\"progress\">Working</summary>",
      "",
      "<details>",
      "<summary>Ran commands</summary>",
      "",
      "x".repeat(90_000),
      "</details>",
      "</details>",
    ].join("\n")

    const result = await editMessage({
      messageId,
      peer: privateChatPeerId,
      text: source,
      parseMarkdown: true,
    }, context)
    const message = extractEditedMessage(result)
    expect(message?.message?.length).toBeGreaterThan(90_000)
    expect(message?.blockContent?.blocks).toHaveLength(1)
  })

  test("parses markdown when parseMarkdown is enabled", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial",
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    const result = await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: "hello **world** and `code`",
        parseMarkdown: true,
      },
      context,
    )

    const message = extractEditedMessage(result)
    expect(message).toBeTruthy()
    expect(message?.message).toBe("hello world and code")
    expect(message?.entities?.entities).toHaveLength(2)
    expect(message?.entities?.entities[0]?.type).toBe(MessageEntity_Type.BOLD)
    expect(message?.entities?.entities[0]?.offset).toBe(6n)
    expect(message?.entities?.entities[0]?.length).toBe(5n)
    expect(message?.entities?.entities[1]?.type).toBe(MessageEntity_Type.CODE)
    expect(message?.entities?.entities[1]?.offset).toBe(16n)
    expect(message?.entities?.entities[1]?.length).toBe(4n)
  })

  test("preserves markdown syntax when parseMarkdown is explicitly disabled", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial raw markdown",
      },
      context,
    )
    const messageId = extractSentMessageId(sent)
    expect(messageId).toBeTruthy()

    const text = "hello **world** and `code`"
    const result = await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text,
        parseMarkdown: false,
      },
      context,
    )

    const message = extractEditedMessage(result)
    expect(message?.message).toBe(text)
    expect(message?.entities).toBeUndefined()
  })

  test("preserves markdown syntax for normal user RPC when parseMarkdown is omitted", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial omitted markdown flag",
      },
      context,
    )
    const messageId = extractSentMessageId(sent)
    expect(messageId).toBeTruthy()

    const text = "hello **world** and `code`"
    const result = await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text,
      },
      context,
    )

    const message = extractEditedMessage(result)
    expect(message?.message).toBe(text)
    expect(message?.entities).toBeUndefined()
  })

  test("suppresses edit date for bot streaming edits without changing the user path", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial bot stream",
      },
      context,
    )
    const messageId = extractSentMessageId(sent)
    expect(messageId).toBeTruthy()

    const result = await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: "streaming **answer**",
        parseMarkdown: true,
      },
      { ...context, isBot: true },
    )

    const message = extractEditedMessage(result)
    expect(message).toBeTruthy()
    expect(message?.editDate).toBeUndefined()

    const [stored] = await db
      .select({ editDate: messages.editDate })
      .from(messages)
      .where(and(eq(messages.chatId, privateChat.id), eq(messages.messageId, Number(messageId))))
      .limit(1)
    expect(stored?.editDate).toBeNull()
  })

  test("reuses a stable Markdown image job across streaming edits", async () => {
    const imageUrl = "https://example.com/live-stream-image.png"
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: `# Draft\n\n![Preview](${imageUrl})`,
        parseMarkdown: true,
      },
      context,
    )
    const messageId = extractSentMessageId(sent)
    expect(messageId).toBeTruthy()

    const [beforeMessage] = await db
      .select({ blockContentId: messages.blockContentId })
      .from(messages)
      .where(and(eq(messages.chatId, privateChat.id), eq(messages.messageId, Number(messageId))))
      .limit(1)
    expect(beforeMessage?.blockContentId).toBeTruthy()

    const beforeJobs = await db
      .select()
      .from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.contentId, beforeMessage!.blockContentId!))
    expect(beforeJobs).toHaveLength(1)

    await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: `# Final answer\n\n![Updated preview](${imageUrl})`,
        parseMarkdown: true,
      },
      { ...context, isBot: true },
    )

    const afterJobs = await db
      .select()
      .from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.contentId, beforeMessage!.blockContentId!))
    expect(afterJobs).toHaveLength(1)
    expect(afterJobs[0]?.id).toBe(beforeJobs[0]?.id)
    expect(afterJobs[0]?.expectedRevision).toBe(1)
    expect(afterJobs[0]?.state).toBe("pending")
  })

  test("keeps thread links current when image enrichment advances the message revision", async () => {
    const source = await testUtils.createChat(null, "Image graph source", "thread", false, currentUser.id)
    const target = await testUtils.createChat(null, "Image graph target", "thread", false, currentUser.id)
    if (!source || !target) throw new Error("Failed to create image graph chats")
    await testUtils.addParticipant(source.id, currentUser.id)
    await testUtils.addParticipant(target.id, currentUser.id)
    const sourcePeer: InputPeer = {
      type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } },
    }

    const sent = await sendMessage({ peerId: sourcePeer, message: "draft" }, context)
    const messageId = extractSentMessageId(sent)
    expect(messageId).toBeTruthy()

    const edited = await editMessage(
      {
        messageId: messageId!,
        peer: sourcePeer,
        text: `[target](inline://thread?id=${target.id})\n\n![Preview](https://images.example.test/graph.png)`,
        parseMarkdown: true,
      },
      context,
    )
    expect(extractEditedMessage(edited)?.entities?.entities.some(
      (entity) => entity.type === MessageEntity_Type.THREAD,
    )).toBe(true)

    const beforeLinks = await waitForThreadGraphLinks({
      fromChatId: source.id,
      fromMessageId: Number(messageId),
      count: 1,
      withBacklink: true,
    })
    expect(beforeLinks[0]?.fromMessageRevision).toBe(1)

    const [storedMessage] = await db
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, source.id), eq(messages.messageId, Number(messageId))))
      .limit(1)
    if (!storedMessage?.blockContentId) throw new Error("Expected rich message")

    const [storedContent] = await db
      .select()
      .from(blockContents)
      .where(eq(blockContents.id, storedMessage.blockContentId))
      .limit(1)
    if (!storedContent) throw new Error("Expected stored rich content")
    const legacySnapshot = decryptStoredBlockContent({
      encrypted: storedContent.payloadEncrypted,
      iv: storedContent.payloadIv,
      authTag: storedContent.payloadTag,
    })
    legacySnapshot.blockContent.blocks.push({
      kind: {
        oneofKind: "table",
        table: {
          alignments: Array.from({ length: 16 }, () => BlockTable_Alignment.LEFT),
          rows: Array.from({ length: 17 }, () => ({
            cells: Array.from({ length: 16 }, () => ({ offset: 0n, length: 1n })),
          })),
        },
      },
    })
    const legacyPayload = encryptStoredBlockContent(legacySnapshot)
    await db
      .update(blockContents)
      .set({
        payloadEncrypted: legacyPayload.encrypted,
        payloadIv: legacyPayload.iv,
        payloadTag: legacyPayload.authTag,
      })
      .where(eq(blockContents.id, storedMessage.blockContentId))

    const leaseToken = crypto.randomUUID()
    const [job] = await db
      .update(blockContentImageJobs)
      .set({
        state: "processing",
        leaseToken,
        leaseUntil: new Date(Date.now() + 60_000),
      })
      .where(eq(blockContentImageJobs.contentId, storedMessage.blockContentId))
      .returning()
    if (!job) throw new Error("Expected image job")

    const [photo] = await db
      .insert(photos)
      .values({ format: "jpeg", width: 1, height: 1 })
      .returning({ id: photos.id })
    if (!photo) throw new Error("Expected image photo")

    expect(await publishClaimedBlockImageJobForTests(
      { ...job, leaseToken },
      {
        oneofKind: "ready",
        ready: {
          id: BigInt(photo.id),
          date: 1n,
          format: Photo_Format.JPEG,
          sizes: [],
        },
      },
    )).toBe("published")

    const [afterMessage] = await db
      .select({ rev: messages.rev })
      .from(messages)
      .where(and(eq(messages.chatId, source.id), eq(messages.messageId, Number(messageId))))
      .limit(1)
    expect(afterMessage?.rev).toBe(2)

    const afterLinks = await waitForThreadGraphLinks({
      fromChatId: source.id,
      fromMessageId: Number(messageId),
      count: 1,
      withBacklink: true,
    })
    expect(afterLinks[0]?.fromMessageRevision).toBe(2)

    const projected = await getOutlinks({
      chatId: source.id,
      currentUserId: currentUser.id,
      kind: "thread_link",
    })
    expect(projected.links.some((link) => link.id === afterLinks[0]?.id)).toBe(true)
  })

  test("resolves @username mentions while parsing markdown edits", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("edit-mentioned"))
    await db.update(users).set({ username: "editmentioned" }).where(eq(users.id, mentionedUser!.id)).execute()

    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial mention",
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    const result = await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: "check **@editmentioned**",
        parseMarkdown: true,
      },
      context,
    )

    const message = extractEditedMessage(result)
    const sendReference = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "check **@editmentioned**",
        parseMarkdown: true,
      },
      context,
    )
    const sentMessage =
      sendReference.updates[1]?.update.oneofKind === "newMessage"
        ? sendReference.updates[1].update.newMessage?.message
        : null

    expect(message).toBeTruthy()
    expect(sentMessage).toBeTruthy()
    expect(message?.message).toBe("check @editmentioned")
    expect(message?.entities).toEqual(sentMessage?.entities)
    expect(message?.entities?.entities[0]?.type).toBe(MessageEntity_Type.BOLD)
  })

  test("includes explicit empty actions in edit updates when clearing bot buttons", async () => {
    await db.update(users).set({ bot: true }).where(eq(users.id, currentUser.id)).execute()

    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "with buttons",
        actions: {
          rows: [
            {
              actions: [
                {
                  actionId: "approve",
                  text: "Approve",
                  action: {
                    oneofKind: "callback",
                    callback: {
                      data: new Uint8Array([1, 2, 3]),
                    },
                  },
                },
              ],
            },
          ],
        },
      },
      context,
    )

    const sentMessageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(sentMessageId).toBeTruthy()

    const result = await editMessage(
      {
        messageId: sentMessageId!,
        peer: privateChatPeerId,
        text: "buttons cleared",
        actions: { rows: [] },
      },
      context,
    )

    const editedMessage = extractEditedMessage(result)
    expect(editedMessage).toBeTruthy()
    expect(editedMessage?.message).toBe("buttons cleared")
    expect(editedMessage?.actions).toBeTruthy()
    expect(editedMessage?.actions?.rows).toEqual([])
  })

  test("rejects editing another user's message", async () => {
    const otherUser = (await testUtils.createUser(nextEmail("edit-other")))!
    const sharedChat = (await testUtils.createPrivateChat(currentUser, otherUser))!
    const peer: InputPeer = {
      type: { oneofKind: "chat", chat: { chatId: BigInt(sharedChat.id) } },
    }
    const otherContext = testUtils.functionContext({ userId: otherUser.id, sessionId: 2 })
    const sent = await sendMessage({ peerId: peer, message: "other user's message" }, otherContext)
    const messageId = extractSentMessageId(sent)
    expect(messageId).toBeTruthy()

    await expect(
      editMessage(
        {
          messageId: messageId!,
          peer,
          text: "forged terminal result",
        },
        context,
      ),
    ).rejects.toMatchObject({ codeName: "BAD_REQUEST" })

    const [stored] = await db
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, sharedChat.id), eq(messages.messageId, Number(messageId))))
      .limit(1)
    expect(stored?.fromId).toBe(otherUser.id)
    expect(stored?.rev).toBe(0)
  })

  test("preserves voice media when editing voice message text", async () => {
    const voice = await createVoiceForUser(currentUser.id)
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        voiceId: BigInt(voice.id),
      },
      context,
    )

    const sentMessageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(sentMessageId).toBeTruthy()

    const result = await editMessage(
      {
        messageId: sentMessageId!,
        peer: privateChatPeerId,
        text: "voice transcript",
      },
      context,
    )

    const editedMessage = extractEditedMessage(result)
    expect(editedMessage?.message).toBe("voice transcript")
    expect(editedMessage?.media?.media.oneofKind).toBe("voice")
  })

  test("replaces explicit thread graph links when editing message entities", async () => {
    const source = await testUtils.createChat(null, "Graph source", "thread", false, currentUser.id)
    const target = await testUtils.createChat(null, "Graph target", "thread", false, currentUser.id)
    if (!source || !target) {
      throw new Error("Failed to create graph test chats")
    }

    await testUtils.addParticipant(source.id, currentUser.id)
    await testUtils.addParticipant(target.id, currentUser.id)

    const sent = await sendMessage(
      {
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } } },
        message: "see target",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.THREAD,
              offset: 4n,
              length: 6n,
              entity: {
                oneofKind: "thread",
                thread: { chatId: BigInt(target.id) },
              },
            },
          ],
        },
      },
      context,
    )

    const sentMessageId = extractSentMessageId(sent)
    expect(sentMessageId).toBeTruthy()

    const link = await waitForThreadGraphLinks({
      fromChatId: source.id,
      fromMessageId: Number(sentMessageId),
      count: 1,
      withBacklink: true,
    }).then((links) => links[0])

    const backlinkMessageGlobalId = link?.backlinkMessageGlobalId
    expect(backlinkMessageGlobalId).toBeTruthy()

    expect(link).toMatchObject({
      kind: "thread_link",
      scopeType: "user",
      scopeId: currentUser.id,
      fromChatId: source.id,
      fromMessageId: Number(sentMessageId),
      fromMessageRevision: 0,
      entityIndex: 0,
      toChatId: target.id,
      deletedAt: null,
    })

    const [backlinkMessage] = await db
      .select()
      .from(messages)
      .where(eq(messages.globalId, backlinkMessageGlobalId!))
      .limit(1)
    expect(backlinkMessage).toBeTruthy()
    expect(backlinkMessage?.chatId).toBe(target.id)
    expect(backlinkMessage?.systemMessageEncrypted).toBeTruthy()

    await editMessage(
      {
        messageId: sentMessageId!,
        peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } } },
        text: "no link",
      },
      context,
    )

    await waitForThreadGraphLinks({
      fromChatId: source.id,
      fromMessageId: Number(sentMessageId),
      count: 0,
    })
    await waitForMessageDeletion(backlinkMessageGlobalId!)

    const inactiveLinks = await db
      .select()
      .from(threadGraphLinks)
      .where(
        and(
          eq(threadGraphLinks.kind, "thread_link"),
          eq(threadGraphLinks.fromChatId, source.id),
          eq(threadGraphLinks.fromMessageId, Number(sentMessageId)),
        ),
      )
    expect(inactiveLinks).toHaveLength(1)
    expect(inactiveLinks[0]?.deletedAt).toBeTruthy()
    expect(inactiveLinks[0]?.backlinkMessageGlobalId).toBeNull()

    const deletedBacklinkMessages = await db
      .select({ globalId: messages.globalId })
      .from(messages)
      .where(eq(messages.globalId, backlinkMessageGlobalId!))
    expect(deletedBacklinkMessages).toHaveLength(0)
  })

  test("ignores stale thread graph materialization after a newer edit revision", async () => {
    const source = await testUtils.createChat(null, "Stale graph source", "thread", false, currentUser.id)
    const currentTarget = await testUtils.createChat(null, "Current graph target", "thread", false, currentUser.id)
    const staleTarget = await testUtils.createChat(null, "Stale graph target", "thread", false, currentUser.id)
    if (!source || !currentTarget || !staleTarget) {
      throw new Error("Failed to create stale graph test chats")
    }

    await testUtils.addParticipant(source.id, currentUser.id)
    await testUtils.addParticipant(currentTarget.id, currentUser.id)
    await testUtils.addParticipant(staleTarget.id, currentUser.id)

    const peer: InputPeer = {
      type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } },
    }
    const sent = await sendMessage({ peerId: peer, message: "draft" }, context)
    const messageId = extractSentMessageId(sent)
    expect(messageId).toBeTruthy()

    await editMessage(
      {
        messageId: messageId!,
        peer,
        text: "current target",
        entities: threadEntities(currentTarget.id),
      },
      context,
    )

    const currentLinks = await waitForThreadGraphLinks({
      fromChatId: source.id,
      fromMessageId: Number(messageId),
      count: 1,
      withBacklink: true,
    })
    expect(currentLinks[0]?.fromMessageRevision).toBe(1)

    const [sourceMessage] = await db
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, source.id), eq(messages.messageId, Number(messageId))))
      .limit(1)
    if (!sourceMessage) throw new Error("Expected source message")

    expect(await replaceMessageThreadLinks({
      sourceChat: source,
      sourceChatId: source.id,
      sourceMessageGlobalId: sourceMessage.globalId,
      sourceMessageId: sourceMessage.messageId,
      sourceMessageFromId: sourceMessage.fromId,
      sourceMessageRevision: 0,
      entities: undefined,
    })).toEqual([])

    expect(await replaceMessageThreadLinks({
      sourceChat: source,
      sourceChatId: source.id,
      sourceMessageGlobalId: sourceMessage.globalId,
      sourceMessageId: sourceMessage.messageId,
      sourceMessageFromId: sourceMessage.fromId,
      sourceMessageRevision: 0,
      entities: threadEntities(staleTarget.id),
    })).toEqual([])

    const activeLinks = await waitForThreadGraphLinks({
      fromChatId: source.id,
      fromMessageId: Number(messageId),
      count: 1,
      withBacklink: true,
    })
    expect(activeLinks[0]).toMatchObject({
      fromMessageRevision: 1,
      toChatId: currentTarget.id,
      deletedAt: null,
    })

    await db
      .update(threadGraphLinks)
      .set({ fromMessageRevision: 0 })
      .where(eq(threadGraphLinks.id, activeLinks[0]!.id))

    const projectedOutlinks = await getOutlinks({
      chatId: source.id,
      currentUserId: currentUser.id,
      kind: "thread_link",
    })
    expect(projectedOutlinks.links.some((link) => link.id === activeLinks[0]!.id)).toBe(false)
  })
})

function threadEntities(chatId: number) {
  return {
    entities: [
      {
        type: MessageEntity_Type.THREAD,
        offset: 0n,
        length: 6n,
        entity: {
          oneofKind: "thread" as const,
          thread: { chatId: BigInt(chatId) },
        },
      },
    ],
  }
}

async function waitForThreadGraphLinks(input: {
  fromChatId: number
  fromMessageId: number
  count: number
  withBacklink?: boolean
}) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const links = await db
      .select()
      .from(threadGraphLinks)
      .where(
        and(
          eq(threadGraphLinks.kind, "thread_link"),
          eq(threadGraphLinks.fromChatId, input.fromChatId),
          eq(threadGraphLinks.fromMessageId, input.fromMessageId),
          isNull(threadGraphLinks.deletedAt),
        ),
      )

    if (links.length === input.count && (!input.withBacklink || links.every((link) => link.backlinkMessageGlobalId))) {
      return links
    }

    await sleep(10)
  }

  throw new Error(`Expected ${input.count} graph links for message ${input.fromChatId}:${input.fromMessageId}`)
}

async function waitForMessageDeletion(globalId: bigint): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const [message] = await db
      .select({ globalId: messages.globalId })
      .from(messages)
      .where(eq(messages.globalId, globalId))
      .limit(1)

    if (!message) return
    await sleep(10)
  }

  throw new Error(`Expected message ${globalId} to be deleted`)
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
