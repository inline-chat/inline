import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import {
  blockContentImageJobs,
  blockContents,
  chatParticipants,
  documents,
  files,
  messages,
  photoSizes,
  photos,
} from "@in/server/db/schema"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { ensureBotFileAccess } from "./operations"

describe("Bot file access", () => {
  setupTestLifecycle()

  test("allows Bot-owned files and files in currently accessible messages", async () => {
    const bot = await testUtils.createUser(`bot-file-${crypto.randomUUID()}@example.com`)
    const human = await testUtils.createUser(`human-file-${crypto.randomUUID()}@example.com`)
    const [owned, shared] = await db
      .insert(files)
      .values([
        { fileUniqueId: `owned-${crypto.randomUUID()}`, userId: bot.id },
        { fileUniqueId: `shared-${crypto.randomUUID()}`, userId: human.id },
      ])
      .returning()
    expect(owned).toBeDefined()
    expect(shared).toBeDefined()
    await expect(ensureBotFileAccess(owned!, bot.id)).resolves.toBeUndefined()

    const chat = await testUtils.createChat(null, "Shared media", "thread", false, human.id)
    if (!chat) throw new Error("Failed to create shared-media chat")
    await testUtils.addParticipant(chat.id, bot.id)
    const [document] = await db.insert(documents).values({ fileId: shared!.id }).returning()
    await db.insert(messages).values({
      messageId: 1,
      chatId: chat.id,
      fromId: human.id,
      mediaType: "document",
      documentId: document!.id,
    })

    await expect(ensureBotFileAccess(shared!, bot.id)).resolves.toBeUndefined()
    await db
      .delete(chatParticipants)
      .where(and(eq(chatParticipants.chatId, chat.id), eq(chatParticipants.userId, bot.id)))
    AccessGuardsCache.resetChatParticipant(chat.id, bot.id)
    await expect(ensureBotFileAccess(shared!, bot.id)).rejects.toBeDefined()
  })

  test("does not expose an unrelated user's file", async () => {
    const bot = await testUtils.createUser(`bot-private-file-${crypto.randomUUID()}@example.com`)
    const human = await testUtils.createUser(`human-private-file-${crypto.randomUUID()}@example.com`)
    const [file] = await db
      .insert(files)
      .values({ fileUniqueId: `private-${crypto.randomUUID()}`, userId: human.id })
      .returning()
    await expect(ensureBotFileAccess(file!, bot.id)).rejects.toBeDefined()
  })

  test("allows files referenced by rich block images in an accessible chat", async () => {
    const bot = await testUtils.createUser(`bot-block-file-${crypto.randomUUID()}@example.com`)
    const human = await testUtils.createUser(`human-block-file-${crypto.randomUUID()}@example.com`)
    const [file] = await db.insert(files).values({
      fileUniqueId: `block-${crypto.randomUUID()}`,
      userId: human.id,
      fileType: "photo",
    }).returning()
    const [photo] = await db.insert(photos).values({ format: "jpeg" }).returning()
    await db.insert(photoSizes).values({
      fileId: file!.id,
      photoId: photo!.id,
      size: "f",
    })
    const [content] = await db.insert(blockContents).values({
      payloadEncrypted: Buffer.from([1]),
      payloadIv: Buffer.from([2]),
      payloadTag: Buffer.from([3]),
    }).returning()
    await db.insert(blockContentImageJobs).values({
      contentId: content!.id,
      expectedRevision: 0,
      blockPath: [0],
      sourceHash: Buffer.from([4]),
      sourceEncrypted: Buffer.from([5]),
      sourceIv: Buffer.from([6]),
      sourceTag: Buffer.from([7]),
      state: "ready",
      photoId: photo!.id,
    })
    const chat = await testUtils.createChat(null, "Rich blocks", "thread", false, human.id)
    if (!chat) throw new Error("Failed to create rich-block chat")
    await testUtils.addParticipant(chat.id, bot.id)
    await db.insert(messages).values({
      messageId: 1,
      chatId: chat.id,
      fromId: human.id,
      blockContentId: content!.id,
    })

    await expect(ensureBotFileAccess(file!, bot.id)).resolves.toBeUndefined()
  })
})
