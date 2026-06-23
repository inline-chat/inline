import { afterAll, describe, expect, test, beforeAll } from "bun:test"
import { setupTestDatabase, setupTestLifecycle, teardownTestDatabase, testUtils } from "../setup"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { files, photos, photoSizes } from "@in/server/db/schema"
import { decrypt, decryptBinary, encryptBinary } from "@in/server/modules/encryption/encryption"
import {
  MessageEntities,
  MessageEntity_MessageEntityMention,
  MessageEntity_Type,
  RichDirection,
  RichMessage,
  type RichBlock,
} from "@inline-chat/protocol/core"
import { RichTextValidationError, normalizeRichMessage } from "@in/server/modules/message/richText"

describe("editMessage", () => {
  let userId: number
  let chatId: number

  // Setup
  beforeAll(async () => {
    await setupTestDatabase()
    let user = await testUtils.createUser("test@test.com")
    let chat = await testUtils.createTestChat()

    userId = user!.id
    chatId = chat!.id
  })
  afterAll(teardownTestDatabase)

  // Tests
  test("edits plain text message", async () => {
    await testUtils.createTestMessage({
      messageId: 1,
      fromId: userId,
      chatId: chatId,
      text: "test",
    })

    let { message: edited } = (await MessageModel.editMessage({
      messageId: 1,
      chatId: chatId,
      text: "edited",
    }))!

    expect(edited).toBeTruthy()

    let text = decrypt({
      authTag: edited.textTag!,
      iv: edited.textIv!,
      encrypted: edited.textEncrypted!,
    })

    expect(text).toBe("edited")
    expect(edited?.editDate).toBeDate()
  })

  test("edits message with entities", async () => {
    await testUtils.createTestMessage({
      messageId: 2,
      fromId: userId,
      chatId: chatId,
      text: "@mo",
      entities: testUtils.mentionEntities(0, 3),
    })

    let { message: edited } = (await MessageModel.editMessage({
      messageId: 2,
      chatId: chatId,
      text: "edited @mo",
      entities: testUtils.mentionEntities(7, 3),
    }))!

    expect(edited).toBeTruthy()

    let text = decrypt({
      authTag: edited.textTag!,
      iv: edited.textIv!,
      encrypted: edited.textEncrypted!,
    })

    let entities = MessageEntities.fromBinary(
      decryptBinary({
        authTag: edited.entitiesTag!,
        iv: edited.entitiesIv!,
        encrypted: edited.entitiesEncrypted!,
      }),
    )

    expect(text).toBe("edited @mo")
    expect(entities.entities[0]?.type).toBe(MessageEntity_Type.MENTION)
    expect(entities.entities[0]?.offset).toBe(7n)
    expect(entities.entities[0]?.length).toBe(3n)
  })

  test("it should not fail when entities are cleared", async () => {
    await testUtils.createTestMessage({
      messageId: 3,
      fromId: userId,
      chatId: chatId,
      text: "test",
    })

    let edited = (await MessageModel.editMessage({
      messageId: 3,
      chatId: chatId,
      text: "edited",
      entities: undefined,
    }))!

    expect(edited).toBeTruthy()
  })

  test("strips thinking blocks from rich text during durable insert", async () => {
    const chat = await testUtils.createTestChat()
    const source = normalizeRichMessage(richTextWithThinking(), { allowThinking: true })
    const encrypted = encryptBinary(RichMessage.toBinary(source))

    const { message } = await MessageModel.insertMessage({
      chatId: chat!.id,
      fromId: userId,
      textEncrypted: null,
      textIv: null,
      textTag: null,
      entitiesEncrypted: null,
      entitiesIv: null,
      entitiesTag: null,
      richTextEncrypted: encrypted.encrypted,
      richTextIv: encrypted.iv,
      richTextTag: encrypted.authTag,
      richTextIndex: source,
      date: new Date(),
    })

    const stored = decodeRichText(message)
    expect(stored?.blocks.map((block) => block.block.oneofKind)).toEqual(["paragraph"])
    expect(stored?.fallbackText).toBe("public")
  })

  test("strips thinking blocks from rich text during durable edit", async () => {
    await testUtils.createTestMessage({
      messageId: 4,
      fromId: userId,
      chatId: chatId,
      text: "test",
    })

    const source = normalizeRichMessage(richTextWithThinking(), { allowThinking: true })
    const { message } = await MessageModel.editMessage({
      messageId: 4,
      chatId,
      text: source.fallbackText,
      richText: source,
    })

    const stored = decodeRichText(message)
    expect(stored?.blocks.map((block) => block.block.oneofKind)).toEqual(["paragraph"])
    expect(stored?.fallbackText).toBe("public")
  })

  test("rejects invalid internal rich media refs during durable insert", async () => {
    const chat = await testUtils.createTestChat()

    await expect(
      MessageModel.insertMessage({
        chatId: chat!.id,
        fromId: userId,
        textEncrypted: null,
        textIv: null,
        textTag: null,
        entitiesEncrypted: null,
        entitiesIv: null,
        entitiesTag: null,
        richTextIndex: richPhotoMessage(9_999_999),
        date: new Date(),
      }),
    ).rejects.toBeInstanceOf(RichTextValidationError)
  })

  test("rejects invalid internal rich media refs during durable edit", async () => {
    await testUtils.createTestMessage({
      messageId: 5,
      fromId: userId,
      chatId: chatId,
      text: "test",
    })

    await expect(
      MessageModel.editMessage({
        messageId: 5,
        chatId,
        text: "invalid rich media",
        richText: richPhotoMessage(9_999_999),
      }),
    ).rejects.toBeInstanceOf(RichTextValidationError)
  })

  test("rejects internal rich media refs owned by another user during durable insert", async () => {
    const chat = await testUtils.createTestChat()
    const otherUser = await testUtils.createUser("rich-media-owner-insert@test.com")
    const photo = await createPhotoForUser(otherUser!.id)

    await expect(
      MessageModel.insertMessage({
        chatId: chat!.id,
        fromId: userId,
        textEncrypted: null,
        textIv: null,
        textTag: null,
        entitiesEncrypted: null,
        entitiesIv: null,
        entitiesTag: null,
        richTextIndex: richPhotoMessage(photo.id),
        date: new Date(),
      }),
    ).rejects.toBeInstanceOf(RichTextValidationError)
  })

  test("rejects internal rich media refs owned by another user during durable edit", async () => {
    await testUtils.createTestMessage({
      messageId: 6,
      fromId: userId,
      chatId: chatId,
      text: "test",
    })
    const otherUser = await testUtils.createUser("rich-media-owner-edit@test.com")
    const photo = await createPhotoForUser(otherUser!.id)

    await expect(
      MessageModel.editMessage({
        messageId: 6,
        chatId,
        text: "foreign rich media",
        richText: richPhotoMessage(photo.id),
      }),
    ).rejects.toBeInstanceOf(RichTextValidationError)
  })
})

function decodeRichText(message: {
  richTextEncrypted: Buffer | null
  richTextIv: Buffer | null
  richTextTag: Buffer | null
}): RichMessage | null {
  if (!message.richTextEncrypted || !message.richTextIv || !message.richTextTag) {
    return null
  }

  return RichMessage.fromBinary(
    decryptBinary({
      encrypted: message.richTextEncrypted,
      iv: message.richTextIv,
      authTag: message.richTextTag,
    }),
  )
}

function richTextWithThinking(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "thinking",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "thinking",
          thinking: {
            initiallyCollapsed: true,
            blocks: [paragraphBlock("private")],
          },
        },
      },
      paragraphBlock("public"),
    ],
  }
}

function paragraphBlock(text: string): RichBlock {
  return {
    blockId: `paragraph-${text}`,
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "paragraph",
      paragraph: {
        text: [
          {
            text,
            children: [],
            styles: [],
          },
        ],
      },
    },
  }
}

function richPhotoMessage(photoId: number): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "invalid photo",
    blocks: [
      {
        blockId: "photo",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "photo",
          photo: {
            media: {
              alt: "invalid photo",
              width: 320,
              height: 180,
              media: { oneofKind: "photoId", photoId: BigInt(photoId) },
            },
            caption: [],
          },
        },
      },
    ],
  }
}

async function createPhotoForUser(userId: number) {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `MODEL-RICH-PHOTO-${userId}-${Date.now()}-${Math.random()}`,
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
