import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import {
  InputPeer,
  Message,
  MessageEntity_Type,
  type EditMessageResult,
} from "@inline-chat/protocol/core"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { files, messages, threadGraphLinks, users, voices } from "@in/server/db/schema"
import { and, eq, isNull } from "drizzle-orm"

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
})

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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
