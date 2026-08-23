import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { chatParticipants, documents, files, messages } from "@in/server/db/schema"
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
})
