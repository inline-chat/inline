import { describe, expect, it } from "bun:test"
import { eq } from "drizzle-orm"
import { app } from "../legacyServer"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { SessionsModel } from "@in/server/db/models/sessions"
import { documents, files, users } from "@in/server/db/schema"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { generateToken, hashToken } from "@in/server/utils/auth"
import { setupTestLifecycle, testUtils } from "./setup"

const createBot = async () => {
  const [bot] = await db
    .insert(users)
    .values({ firstName: "Media", username: `media${crypto.randomUUID().slice(0, 8)}bot`, bot: true })
    .returning()
  if (!bot) throw new Error("Failed to create bot")
  const { token } = await generateToken(bot.id)
  await SessionsModel.create({ userId: bot.id, tokenHash: hashToken(token), personalData: {}, clientType: "api" })
  return { bot, token }
}

const createFile = async (userId: number, fileType: "document") => {
  const [file] = await db
    .insert(files)
    .values({ fileUniqueId: `${fileType}-${crypto.randomUUID()}`, userId, fileType, fileSize: 128 })
    .returning()
  if (!file) throw new Error("Failed to create file")
  return file
}

const post = (token: string, path: string, body: unknown) =>
  app.handle(
    new Request(`http://localhost${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
  )

/** A private thread shared by a person and a bot, holding one document the person sent. */
const setup = async () => {
  const human = await testUtils.createUser(`media-human-${crypto.randomUUID()}@example.com`)
  const { bot, token } = await createBot()
  const chat = await testUtils.createChat(null, "Media thread", "thread", false, human.id)
  if (!chat) throw new Error("Failed to create thread")
  await testUtils.addParticipant(chat.id, human.id)
  await testUtils.addParticipant(chat.id, bot.id)

  const documentFile = await createFile(human.id, "document")
  const [document] = await db.insert(documents).values({ fileId: documentFile.id }).returning()
  await sendMessage(
    { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }, documentId: BigInt(document!.id) },
    testUtils.functionContext({ userId: human.id, sessionId: 1 }),
  )
  return { human, bot, token, chat, documentFile }
}

describe("Media reuse over HTTP", () => {
  setupTestLifecycle()

  it("lets a bot copy a user's media with forwardMessage and then reuse its own copy", async () => {
    const { bot, token, chat } = await setup()

    const copied = await post(token, "/bot/forwardMessage", {
      chat_id: chat.id,
      from_chat_id: chat.id,
      message_id: 1,
      copy: true,
    })
    expect(copied.status).toBe(200)
    const copiedJson = await copied.json()
    expect(copiedJson.ok).toBe(true)

    const stored = await MessageModel.getMessage(copiedJson.result.message.message_id, chat.id)
    expect(stored.fromId).toBe(bot.id)
    expect(stored.fwdFromMessageId).toBeNull()
    const [copiedDocument] = await db.select().from(documents).where(eq(documents.id, stored.documentId!))
    const [copiedFile] = await db.select().from(files).where(eq(files.id, copiedDocument!.fileId!))
    expect(copiedFile!.userId).toBe(bot.id)

    const resent = await post(token, "/bot/sendMessage", {
      chat_id: chat.id,
      media: { type: "document", file_id: copiedFile!.fileUniqueId },
    })
    expect(resent.status).toBe(200)
    expect((await resent.json()).ok).toBe(true)
  })

  it("keeps the forward header when copy is omitted", async () => {
    const { token, chat } = await setup()

    const forwarded = await post(token, "/bot/forwardMessage", { chat_id: chat.id, from_chat_id: chat.id, message_id: 1 })
    expect(forwarded.status).toBe(200)
    const forwardedJson = await forwarded.json()
    const stored = await MessageModel.getMessage(forwardedJson.result.message.message_id, chat.id)
    expect(stored.fwdFromMessageId).toBe(1)
  })
})
