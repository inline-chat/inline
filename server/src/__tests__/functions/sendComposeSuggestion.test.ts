import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test"
import { sendComposeSuggestion } from "@in/server/functions/messages.sendComposeSuggestion"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { setupTestLifecycle, testUtils } from "../setup"

const mockPushToUser = mock(async () => {})
let restorePushToUser: (() => void) | undefined
let emailCounter = 0
const nextEmail = (label: string) => `${label}-suggest-${++emailCounter}@example.com`

describe("sendComposeSuggestion", () => {
  setupTestLifecycle()

  beforeEach(() => {
    mockPushToUser.mockClear()
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(mockPushToUser)
    restorePushToUser = () => push.mockRestore()
  })

  afterEach(() => {
    restorePushToUser?.()
    restorePushToUser = undefined
  })

  test("delivers a bot's DM suggestion only to its recipient, with the bot as the peer", async () => {
    const bot = await testUtils.createUser(nextEmail("bot"))
    const user = await testUtils.createUser(nextEmail("user"))
    if (!bot || !user) throw new Error("Failed to create users")
    await testUtils.createPrivateChat(bot, user)

    await sendComposeSuggestion(
      {
        peer: { type: { oneofKind: "user", user: { userId: BigInt(user.id) } } },
        userId: user.id,
        text: "  run the tests  ",
        afterMessageId: 42n,
      },
      { currentUserId: bot.id, currentSessionId: 1, isBot: true },
    )

    expect(mockPushToUser).toHaveBeenCalledTimes(1)
    expect(mockPushToUser).toHaveBeenCalledWith(user.id, [
      {
        update: {
          oneofKind: "composeSuggestion",
          composeSuggestion: {
            userId: BigInt(bot.id),
            peerId: { type: { oneofKind: "user", user: { userId: BigInt(bot.id) } } },
            text: "run the tests",
            afterMessageId: 42n,
          },
        },
      },
    ])
  })

  test("sends a thread suggestion to the one participant it names", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Suggest Space", [
      nextEmail("bot"),
      nextEmail("user1"),
      nextEmail("user2"),
    ])
    const [bot, user1] = users
    if (!bot || !user1) throw new Error("Failed to create users")
    const chat = await testUtils.createChat(space.id, "Suggest Thread", "thread")
    if (!chat) throw new Error("Failed to create chat")

    await sendComposeSuggestion(
      { peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }, userId: user1.id, text: "yes" },
      { currentUserId: bot.id, currentSessionId: 1, isBot: true },
    )

    expect(mockPushToUser).toHaveBeenCalledTimes(1)
    expect(mockPushToUser.mock.calls[0]?.[0]).toBe(user1.id)
  })

  test("refuses a sender that is not a bot", async () => {
    const sender = await testUtils.createUser(nextEmail("human"))
    const user = await testUtils.createUser(nextEmail("user"))
    if (!sender || !user) throw new Error("Failed to create users")
    await testUtils.createPrivateChat(sender, user)

    await expect(
      sendComposeSuggestion(
        { peer: { type: { oneofKind: "user", user: { userId: BigInt(user.id) } } }, userId: user.id, text: "hi" },
        { currentUserId: sender.id, currentSessionId: 1, isBot: false },
      ),
    ).rejects.toThrow()
    expect(mockPushToUser).not.toHaveBeenCalled()
  })

  test("refuses a recipient outside the chat", async () => {
    const bot = await testUtils.createUser(nextEmail("bot"))
    const user = await testUtils.createUser(nextEmail("user"))
    const outsider = await testUtils.createUser(nextEmail("outsider"))
    if (!bot || !user || !outsider) throw new Error("Failed to create users")
    await testUtils.createPrivateChat(bot, user)

    await expect(
      sendComposeSuggestion(
        { peer: { type: { oneofKind: "user", user: { userId: BigInt(user.id) } } }, userId: outsider.id, text: "hi" },
        { currentUserId: bot.id, currentSessionId: 1, isBot: true },
      ),
    ).rejects.toThrow()
    expect(mockPushToUser).not.toHaveBeenCalled()
  })

  test("refuses text over the limit", async () => {
    const bot = await testUtils.createUser(nextEmail("bot"))
    const user = await testUtils.createUser(nextEmail("user"))
    if (!bot || !user) throw new Error("Failed to create users")
    await testUtils.createPrivateChat(bot, user)

    await expect(
      sendComposeSuggestion(
        { peer: { type: { oneofKind: "user", user: { userId: BigInt(user.id) } } }, userId: user.id, text: "x".repeat(501) },
        { currentUserId: bot.id, currentSessionId: 1, isBot: true },
      ),
    ).rejects.toThrow()
  })
})
