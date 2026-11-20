import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { messages, translations } from "@in/server/db/schema"
import {
  MAX_TRANSLATE_MESSAGE_IDS,
  TRANSLATION_CHUNK_SIZE,
  TRANSLATION_PROVIDER_RATE_RULE,
  translateMessages,
} from "@in/server/functions/translateMessages"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import type { TranslationCallInput } from "@in/server/modules/translation2/types"
import { RpcError_Code } from "@inline-chat/protocol/core"
import { TranslationModule } from "@in/server/modules/translation2/translation"
import { setupTestLifecycle, testUtils } from "../setup"

let emailCounter = 0
const nextEmail = (label: string) => `translate-${label}-${++emailCounter}@example.com`

describe("translateMessages authorization", () => {
  setupTestLifecycle()

  let provider: ReturnType<typeof spyOn>

  beforeEach(() => {
    provider = spyOn(TranslationModule, "translateMessages").mockImplementation(async () => [])
  })

  afterEach(() => {
    provider.mockRestore()
  })

  const chatPeer = (chatId: number) => ({ type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } })

  test("rejects an outsider naming another pair's DM before reading or translating", async () => {
    const userA = await testUtils.createUser(nextEmail("a"))
    const userB = await testUtils.createUser(nextEmail("b"))
    const outsider = await testUtils.createUser(nextEmail("outsider"))
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Failed to create DM")
    await testUtils.createTestMessage({ messageId: 1, chatId: chat.id, fromId: userA.id, text: "private" })

    await expect(translateMessages(
      { peerId: chatPeer(chat.id), messageIds: [1], language: "fr" },
      { currentUserId: outsider.id, currentSessionId: 1 },
    )).rejects.toThrow()

    expect(provider).not.toHaveBeenCalled()
    expect(await db.select().from(translations).where(eq(translations.chatId, chat.id))).toHaveLength(0)
  })

  test("rejects a non-participant of a private space thread", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Translate Space", [
      nextEmail("participant"),
      nextEmail("member"),
    ])
    const [participant, member] = users
    const chat = await testUtils.createChat(space.id, "Private", "thread", false)
    if (!participant || !member || !chat) throw new Error("Failed to create fixtures")
    await testUtils.addParticipant(chat.id, participant.id)
    await testUtils.createTestMessage({ messageId: 1, chatId: chat.id, fromId: participant.id, text: "private" })

    await expect(translateMessages(
      { peerId: chatPeer(chat.id), messageIds: [1], language: "fr" },
      { currentUserId: member.id, currentSessionId: 1 },
    )).rejects.toThrow()
    expect(provider).not.toHaveBeenCalled()
  })

  test("still translates for a DM participant", async () => {
    const userA = await testUtils.createUser(nextEmail("own-a"))
    const userB = await testUtils.createUser(nextEmail("own-b"))
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Failed to create DM")
    await testUtils.createTestMessage({ messageId: 1, chatId: chat.id, fromId: userB.id, text: "bonjour" })

    await translateMessages(
      { peerId: chatPeer(chat.id), messageIds: [1], language: "en" },
      { currentUserId: userA.id, currentSessionId: 1 },
    )
    expect(provider).toHaveBeenCalledTimes(1)
  })

  async function dmWithMessages(label: string, count: number) {
    const userA = await testUtils.createUser(nextEmail(`${label}-a`))
    const userB = await testUtils.createUser(nextEmail(`${label}-b`))
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) throw new Error("Failed to create DM")
    const text = encryptMessage("bonjour")
    await db.insert(messages).values(
      Array.from({ length: count }, (_, index) => ({
        chatId: chat.id,
        fromId: userB.id,
        messageId: index + 1,
        textEncrypted: text.encrypted,
        textIv: text.iv,
        textTag: text.authTag,
      })),
    )
    const ids = Array.from({ length: count }, (_, index) => index + 1)
    return { chat, ids, context: { currentUserId: userA.id, currentSessionId: 1 } }
  }

  const translateChunk = async (input: TranslationCallInput) =>
    input.messages.map((message) => ({
      translation: `hello ${message.messageId}`,
      messageId: message.messageId,
      chatId: input.chat.id,
      language: input.language,
      entities: null,
      date: new Date(),
      msgRev: message.rev ?? 0,
    }))

  test("saves the chunks the provider translated when another chunk fails", async () => {
    const { chat, ids, context } = await dmWithMessages("chunks", 20)
    provider.mockImplementation(async (input: TranslationCallInput) => {
      if (input.messages.some((message) => message.messageId === 20)) throw new Error("bad provider reply")
      return translateChunk(input)
    })

    const result = await translateMessages({ peerId: chatPeer(chat.id), messageIds: ids, language: "en" }, context)

    expect(provider).toHaveBeenCalledTimes(2)
    // Newest first: 20..6 is the failed chunk, 5..1 is saved.
    expect(result.translations.map((translation) => Number(translation.messageId)).sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5])
    expect(await db.select().from(translations).where(eq(translations.chatId, chat.id))).toHaveLength(20 - TRANSLATION_CHUNK_SIZE)
  })

  test("fails the request when every chunk fails", async () => {
    const { chat, ids, context } = await dmWithMessages("all-fail", 3)
    provider.mockImplementation(async () => {
      throw new Error("provider unavailable")
    })
    await expect(
      translateMessages({ peerId: chatPeer(chat.id), messageIds: ids, language: "en" }, context),
    ).rejects.toThrow("provider unavailable")
  })

  test("clamps a large request to its newest 100 message ids", async () => {
    const { chat, ids, context } = await dmWithMessages("clamp", 120)
    provider.mockImplementation(translateChunk)

    const result = await translateMessages(
      { peerId: chatPeer(chat.id), messageIds: [...ids, ...ids], language: "en" },
      context,
    )

    const calls = provider.mock.calls as [TranslationCallInput][]
    const sent = calls.flatMap(([input]) => input.messages.map((message) => message.messageId))
    expect(sent.sort((a, b) => a - b)).toEqual(ids.slice(-MAX_TRANSLATE_MESSAGE_IDS))
    expect(provider).toHaveBeenCalledTimes(Math.ceil(MAX_TRANSLATE_MESSAGE_IDS / TRANSLATION_CHUNK_SIZE))
    expect(result.translations).toHaveLength(MAX_TRANSLATE_MESSAGE_IDS)
  })

  test("rate-limits provider calls per user", async () => {
    const { chat, ids, context } = await dmWithMessages("rate", MAX_TRANSLATE_MESSAGE_IDS)
    // An empty reply saves nothing, so every request goes back to the provider.
    let rejection: unknown
    for (let request = 0; request < 30 && rejection === undefined; request++) {
      await translateMessages({ peerId: chatPeer(chat.id), messageIds: ids, language: "en" }, context).catch((error) => {
        rejection = error
      })
    }
    expect(rejection).toMatchObject({ code: RpcError_Code.RATE_LIMIT })
    expect(provider).toHaveBeenCalledTimes(TRANSLATION_PROVIDER_RATE_RULE.max)
  })
})
