import { afterEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { messages, users } from "@in/server/db/schema"
import { BotSendPacer, resetBotSendPacingForTests } from "@in/server/modules/pacing/botSendPacing"
import { sendMessage } from "@in/server/realtime/handlers/messages.sendMessage"

const send = (userId: number, chatId: number, text: string, randomId = BigInt(Math.floor(Math.random() * 1_000_000_000))) =>
  sendMessage(
    {
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      message: text,
      randomId,
    },
    { userId, sessionId: 1, connectionId: "bot-pacing-test", sendRaw: () => {}, sendRpcReply: () => {} },
  )

describe("sendMessage bot pacing", () => {
  setupTestLifecycle()

  afterEach(() => {
    resetBotSendPacingForTests()
  })

  test("rejects a bot past its chat budget with a retry-after and writes nothing", async () => {
    resetBotSendPacingForTests(new BotSendPacer(
      { mode: "enforce", perChatBurst: 2, perChatPerSecond: 0.25, perBotBurst: 60, perBotPerSecond: 2, perBotMode: "enforce" },
      Date.now,
      () => {},
    ))
    const human = await testUtils.createUser(`pacing-human-${crypto.randomUUID()}@example.com`)
    const bot = await testUtils.createUser(`pacing-bot-${crypto.randomUUID()}@example.com`)
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))
    const chat = await testUtils.createPrivateChat(human, bot)
    if (!chat) throw new Error("Failed to create chat")

    await send(bot.id, chat.id, "one")
    const retriedRandomId = 424242n
    await send(bot.id, chat.id, "two", retriedRandomId)
    await expect(send(bot.id, chat.id, "three")).rejects.toMatchObject({
      codeNumber: 429,
      retryAfterSeconds: 4,
    })

    // A resend of the committed "two" after a lost result returns its receipt, not a 429.
    const resent = await send(bot.id, chat.id, "two", retriedRandomId)
    expect(resent.updates[0]?.update.oneofKind).toBe("updateMessageId")

    const stored = await db.select({ id: messages.messageId }).from(messages).where(eq(messages.chatId, chat.id))
    expect(stored.length).toBe(2)

    // A human in the same chat has no budget.
    for (let index = 0; index < 4; index += 1) await send(human.id, chat.id, `human ${index}`)
  })
})
