import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { translations } from "@in/server/db/schema"
import { translateMessages } from "@in/server/functions/translateMessages"
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
})
