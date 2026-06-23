import { beforeAll, describe, expect, test } from "bun:test"
import {
  InputPeer,
  Message,
  MessageEntity_Type,
  type RichMessage,
  RichTextStyle,
  type EditMessageResult,
} from "@inline-chat/protocol/core"
import { setupTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { files, messageRichMedia, photos, photoSizes, users, voices } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"

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

async function createPhotoForUser(userId: number) {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `EDIT-PHOTO-${runId}-${userIndex++}`,
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

function richPhotoMessage(photoId: number): RichMessage {
  return {
    version: 1,
    fallbackText: "Embedded rich photo",
    blocks: [
      {
        blockId: "edit-rich-photo",
        block: {
          oneofKind: "photo",
          photo: {
            media: {
              alt: "Edited embedded photo",
              width: 320,
              height: 180,
              media: { oneofKind: "photoId", photoId: BigInt(photoId) },
            },
            caption: [
              {
                text: "Edited rich photo caption",
                children: [],
                styles: [],
              },
            ],
          },
        },
      },
    ],
  }
}

function thinkingOnlyRichText(): RichMessage {
  return {
    version: 1,
    fallbackText: "private reasoning",
    blocks: [
      {
        blockId: "thinking",
        block: {
          oneofKind: "thinking",
          thinking: {
            initiallyCollapsed: true,
            blocks: [
              {
                blockId: "",
                block: {
                  oneofKind: "paragraph",
                  paragraph: { text: [{ text: "private reasoning", children: [], styles: [] }] },
                },
              },
            ],
          },
        },
      },
    ],
  }
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

  test("parses rich markdown edits and returns fallback text plus rich blocks", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial rich edit",
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
        text: "### Edited\n\nUse `code` and **bold**",
        parseRichMarkdown: true,
      },
      context,
    )

    const message = extractEditedMessage(result)
    expect(message).toBeTruthy()
    expect(message?.message).toBe("Edited\n\nUse code and bold")
    expect(message?.richText?.fallbackText).toBe("Edited\n\nUse code and bold")
    expect(message?.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["heading", "paragraph"])
    expect(message?.entities?.entities.map((entity) => entity.type)).toContain(MessageEntity_Type.CODE)
    expect(message?.entities?.entities.map((entity) => entity.type)).toContain(MessageEntity_Type.BOLD)
  })

  test("edits with structured rich text without separate text", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial rich-only edit",
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
        richText: {
          blocks: [
            {
              blockId: "",
              block: {
                oneofKind: "paragraph",
                paragraph: {
                  text: [
                    {
                      text: "rich-only edit",
                      children: [],
                      styles: [RichTextStyle.STYLE_BOLD],
                    },
                  ],
                },
              },
            },
          ],
          fallbackText: "",
          version: 1,
        },
      },
      context,
    )

    const message = extractEditedMessage(result)
    expect(message?.message).toBe("rich-only edit")
    expect(message?.richText?.fallbackText).toBe("rich-only edit")
    expect(message?.entities?.entities).toContainEqual({
      type: MessageEntity_Type.BOLD,
      offset: 0n,
      length: 14n,
      entity: { oneofKind: undefined },
    })
  })

  test("rejects final thinking-only rich text edits instead of writing an empty durable message", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial thinking-only edit",
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    await expect(
      editMessage(
        {
          messageId: messageId!,
          peer: privateChatPeerId,
          text: "private reasoning",
          richText: thinkingOnlyRichText(),
        },
        context,
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("clears stale rich text when editing back to plain text", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "## Rich first",
        parseRichMarkdown: true,
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
        text: "plain now",
      },
      context,
    )

    const message = extractEditedMessage(result)
    expect(message?.message).toBe("plain now")
    expect(message?.richText).toBeUndefined()
    expect(message?.entities).toBeUndefined()
  })

  test("rebuilds rich text media dependency index on edits", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "![Chart](https://example.com/chart.png)",
        parseRichMarkdown: true,
        skipLinkProcessing: true,
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    const initialRows = await db
      .select()
      .from(messageRichMedia)
      .where(and(eq(messageRichMedia.chatId, privateChat.id), eq(messageRichMedia.messageId, Number(messageId))))
    expect(initialRows).toHaveLength(1)

    await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: "plain now",
      },
      context,
    )

    const clearedRows = await db
      .select()
      .from(messageRichMedia)
      .where(and(eq(messageRichMedia.chatId, privateChat.id), eq(messageRichMedia.messageId, Number(messageId))))
    expect(clearedRows).toHaveLength(0)

    await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: "![Updated](https://example.com/updated.png)",
        parseRichMarkdown: true,
      },
      context,
    )

    const rebuiltRows = await db
      .select()
      .from(messageRichMedia)
      .where(and(eq(messageRichMedia.chatId, privateChat.id), eq(messageRichMedia.messageId, Number(messageId))))
    expect(rebuiltRows).toHaveLength(1)
    expect(rebuiltRows[0]?.blockId).toContain("photo")
  })

  test("rejects rich text edits with invalid internal media refs before persistence", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "before invalid rich edit",
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    await expect(
      editMessage(
        {
          messageId: messageId!,
          peer: privateChatPeerId,
          text: "invalid rich edit",
          richText: richPhotoMessage(9_999_999),
        },
        context,
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("rejects rich text edits with internal media refs owned by another user", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "before foreign rich edit",
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    const otherUser = await testUtils.createUser(nextEmail("edit-rich-media-owner"))
    const photo = await createPhotoForUser(otherUser!.id)

    await expect(
      editMessage(
        {
          messageId: messageId!,
          peer: privateChatPeerId,
          text: "not my media",
          richText: richPhotoMessage(photo.id),
        },
        context,
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
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
})
