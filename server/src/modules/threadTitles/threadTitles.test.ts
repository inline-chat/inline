import { afterEach, describe, expect, mock, test } from "bun:test"
import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "../../__tests__/setup"

const parseCompletion = mock()

mock.module("@in/server/libs/openAI", () => ({
  openaiClient: {
    chat: {
      completions: {
        parse: parseCompletion,
      },
    },
  },
}))

const completion = (title: string, emoji?: string | null) => ({
  choices: [
    {
      finish_reason: "stop",
      message: {
        parsed: { title, emoji },
      },
    },
  ],
})

const emptyThread = {
  id: 1,
  type: "thread" as const,
  title: null,
  description: null,
  isUntitled: true,
  parentChatId: null,
  parentMessageId: null,
  minUserId: null,
  maxUserId: null,
}

const textMessage = {
  messageId: 1,
  mediaType: null,
  fwdFromPeerUserId: null,
  fwdFromPeerChatId: null,
  fwdFromMessageId: null,
  fwdFromSenderId: null,
}

describe("thread title generation", () => {
  setupTestLifecycle()

  afterEach(() => {
    parseCompletion.mockReset()
  })

  test("requires substantial non-entity text", async () => {
    const { getThreadTitleSourceText } = await import("@in/server/modules/threadTitles")

    const onlyEntityText = "@alice https://inline.chat"
    const entities: MessageEntities = {
      entities: [
        {
          type: MessageEntity_Type.MENTION,
          offset: 0n,
          length: 6n,
          entity: { oneofKind: "mention", mention: { userId: 2n } },
        },
        {
          type: MessageEntity_Type.URL,
          offset: 7n,
          length: BigInt("https://inline.chat".length),
          entity: { oneofKind: undefined },
        },
        {
          type: MessageEntity_Type.BOT_COMMAND,
          offset: 27n,
          length: 6n,
          entity: { oneofKind: undefined },
        },
      ],
    }

    expect(
      getThreadTitleSourceText({
        chat: emptyThread,
        message: textMessage,
        text: `${onlyEntityText} /start`,
        entities,
        currentUserId: 1,
      }),
    ).toBeUndefined()

    expect(
      getThreadTitleSourceText({
        chat: emptyThread,
        message: textMessage,
        text: "@alice can you write the launch checklist for tomorrow morning",
        entities: {
          entities: [entities.entities[0]!],
        },
        currentUserId: 1,
      }),
    ).toBe("can you write the launch checklist for tomorrow morning")

    expect(
      getThreadTitleSourceText({
        chat: emptyThread,
        message: textMessage,
        text: "ship launch plan",
        entities: undefined,
        currentUserId: 1,
      }),
    ).toBe("ship launch plan")

    expect(
      getThreadTitleSourceText({
        chat: emptyThread,
        message: textMessage,
        text: "ship plan",
        entities: undefined,
        currentUserId: 1,
      }),
    ).toBeUndefined()

    expect(
      getThreadTitleSourceText({
        chat: emptyThread,
        message: textMessage,
        text: "https://www.youtube.com/watch?v=abc123",
        entities: undefined,
        attachments: [
          {
            kind: "urlPreview",
            title: "Roadmap review walkthrough",
            description: "Customer onboarding and launch notes",
            author: "Inline",
            siteName: "YouTube",
          },
        ],
        currentUserId: 1,
      }),
    ).toBe(
      [
        "URL preview title: Roadmap review walkthrough",
        "URL preview description: Customer onboarding and launch notes",
        "URL preview author: Inline",
        "URL preview site: YouTube",
      ].join("\n"),
    )
  })

  test("recognizes only current and exact legacy reply-thread placeholders", async () => {
    const { buildDefaultReplyThreadTitle, isDefaultReplyThreadTitle } = await import(
      "@in/server/modules/subthreads"
    )
    const anchor = {
      text: "This parent message is deliberately long enough to exercise both current and historical title lengths.",
    }
    const currentPlaceholder = buildDefaultReplyThreadTitle(anchor)
    const legacyPlaceholder = `Re: ${anchor.text.slice(0, 72)}`

    expect(isDefaultReplyThreadTitle(currentPlaceholder, anchor)).toBe(true)
    expect(isDefaultReplyThreadTitle(legacyPlaceholder, anchor)).toBe(true)
    expect(isDefaultReplyThreadTitle("Re: An unrelated stored title", anchor)).toBe(false)
    expect(isDefaultReplyThreadTitle("Message", undefined)).toBe(true)
    expect(isDefaultReplyThreadTitle("Re: Message", undefined)).toBe(true)
  })

  test("uses URL preview attachment text when the message body is only a link", async () => {
    parseCompletion.mockResolvedValue(completion("Roadmap Review"))

    const user = await testUtils.createUser("thread-title-preview-user@example.com")
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: user.id,
      })
      .returning()

    if (!chat) {
      throw new Error("Chat not created")
    }

    await testUtils.addParticipant(chat.id, user.id)

    const { maybeScheduleThreadTitleGeneration } = await import("@in/server/modules/threadTitles")
    maybeScheduleThreadTitleGeneration({
      chat,
      message: textMessage,
      text: "https://www.youtube.com/watch?v=abc123",
      entities: undefined,
      attachments: [
        {
          kind: "urlPreview",
          title: "Roadmap review walkthrough",
          description: "Customer onboarding and launch notes",
          author: "Inline",
          siteName: "YouTube",
        },
      ],
      currentUserId: user.id,
    })

    await waitForChatTitle(chat.id, "Roadmap Review")

    const request = parseCompletion.mock.calls[0]?.[0] as
      | { messages?: { role?: string; content?: string }[] }
      | undefined
    const userMessage = request?.messages?.find((message) => message.role === "user")?.content

    expect(userMessage).toContain("URL preview title: Roadmap review walkthrough")
    expect(userMessage).toContain("URL preview description: Customer onboarding and launch notes")
    expect(userMessage).not.toContain("https://www.youtube.com/watch")
  })

  test("sets a generated title only while the thread is untitled", async () => {
    parseCompletion.mockResolvedValue(completion("Launch Checklist 🚀", "🚀"))

    const user = await testUtils.createUser("thread-title-user@example.com")
    const userTimeZone = "Pacific/Honolulu"
    const expectedToday = formatTestDate(userTimeZone)
    await db.update(schema.users).set({ timeZone: userTimeZone }).where(eq(schema.users.id, user.id))

    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: user.id,
      })
      .returning()

    if (!chat) {
      throw new Error("Chat not created")
    }

    await testUtils.addParticipant(chat.id, user.id)

    const { generateAndApplyThreadTitle } = await import("@in/server/modules/threadTitles")
    const result = await generateAndApplyThreadTitle({
      chatId: chat.id,
      messageId: 1,
      text: "Can you write the launch checklist for tomorrow morning before we send the build?",
      currentUserId: user.id,
    })

    expect(result.didUpdate).toBe(true)

    const updated = await db
      .select({ title: schema.chats.title, emoji: schema.chats.emoji, isUntitled: schema.chats.isUntitled })
      .from(schema.chats)
      .where(eq(schema.chats.id, chat.id))
      .then((rows) => rows[0])

    expect(updated?.title).toBe("Launch Checklist")
    expect(updated?.emoji).toBe("🚀")
    expect(updated?.isUntitled).toBe(true)

    const request = parseCompletion.mock.calls[0]?.[0] as
      | {
          model?: string
          reasoning_effort?: string
          messages?: { role?: string; content?: string }[]
        }
      | undefined
    const systemMessage = request?.messages?.find((message) => message.role === "system")?.content
    expect(request?.model).toBe("gpt-5.6-luna")
    expect(request?.reasoning_effort).toBe("none")
    expect(systemMessage).toContain("Default to sentence casing")
    expect(systemMessage).toContain("If the messages themselves are all lowercase")
    expect(systemMessage).toContain("Prefer 3-6 words")
    expect(systemMessage).toContain("One or two words are good")
    expect(systemMessage).toContain("gold standard, not a hard cap")
    expect(systemMessage).toContain("tasteful and understated")
    expect(systemMessage).toContain("not formal, cheesy")
    expect(systemMessage).toContain("append today's date at the end in parentheses")
    expect(systemMessage).toContain(`Today's date is ${expectedToday}`)
    expect(systemMessage).toContain(`for example: (${expectedToday})`)
  })

  test("allows generated titles longer than the old short cap", async () => {
    const longTitle = "Customer onboarding migration checklist and release coordination plan for mobile beta"
    expect(longTitle.length).toBeGreaterThan(70)
    parseCompletion.mockResolvedValue(completion(longTitle))

    const user = await testUtils.createUser("long-thread-title-user@example.com")
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: user.id,
      })
      .returning()

    if (!chat) {
      throw new Error("Chat not created")
    }

    await testUtils.addParticipant(chat.id, user.id)

    const { generateAndApplyThreadTitle } = await import("@in/server/modules/threadTitles")
    const result = await generateAndApplyThreadTitle({
      chatId: chat.id,
      messageId: 1,
      text: "Can you prepare the full customer onboarding migration checklist and coordinate the mobile beta release plan?",
      currentUserId: user.id,
    })

    expect(result.didUpdate).toBe(true)

    const updated = await db
      .select({ title: schema.chats.title })
      .from(schema.chats)
      .where(eq(schema.chats.id, chat.id))
      .then((rows) => rows[0])

    expect(updated?.title).toBe(longTitle)
  })

  test("ignores invalid generated emoji values", async () => {
    parseCompletion.mockResolvedValue(completion("Launch Checklist", "launch"))

    const user = await testUtils.createUser("invalid-thread-emoji-user@example.com")
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: user.id,
      })
      .returning()

    if (!chat) {
      throw new Error("Chat not created")
    }

    await testUtils.addParticipant(chat.id, user.id)

    const { generateAndApplyThreadTitle } = await import("@in/server/modules/threadTitles")
    const result = await generateAndApplyThreadTitle({
      chatId: chat.id,
      messageId: 1,
      text: "Can you write the launch checklist for tomorrow morning before we send the build?",
      currentUserId: user.id,
    })

    expect(result.didUpdate).toBe(true)

    const updated = await db
      .select({ title: schema.chats.title, emoji: schema.chats.emoji })
      .from(schema.chats)
      .where(eq(schema.chats.id, chat.id))
      .then((rows) => rows[0])

    expect(updated?.title).toBe("Launch Checklist")
    expect(updated?.emoji).toBeNull()
  })

  test("generates one reply-thread title from parent context and the first eligible reply", async () => {
    parseCompletion.mockResolvedValue(completion("Beta notification timing", "🚀"))

    const user = await testUtils.createUser("reply-title-user@example.com")
    const anchorAuthor = await testUtils.createUser("reply-title-anchor-author@example.com")
    await db.update(schema.users).set({ firstName: "Mina", lastName: "Park" }).where(eq(schema.users.id, anchorAuthor.id))

    const [parentChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Launch planning",
        description: "Mobile beta release coordination",
        publicThread: false,
        createdBy: user.id,
      })
      .returning()

    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    const anchorText = "Should we move the beta to Thursday after the notification fixes land?"
    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: anchorAuthor.id,
      text: anchorText,
    })

    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: Array.from(anchorText).slice(0, 60).join(""),
        isUntitled: true,
        publicThread: false,
        createdBy: user.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!replyThread) {
      throw new Error("Reply thread not created")
    }

    const { generateAndApplyThreadTitle, maybeScheduleThreadTitleGeneration } = await import(
      "@in/server/modules/threadTitles"
    )
    maybeScheduleThreadTitleGeneration({
      chat: replyThread,
      message: textMessage,
      text: "Yes, after QA signs off on notification delivery and badge counts.",
      entities: undefined,
      currentUserId: user.id,
    })
    await waitForChatTitle(replyThread.id, "Beta notification timing")

    const updated = await db
      .select({ title: schema.chats.title, emoji: schema.chats.emoji, isUntitled: schema.chats.isUntitled })
      .from(schema.chats)
      .where(eq(schema.chats.id, replyThread.id))
      .then((rows) => rows[0])

    expect(updated).toEqual({
      title: "Beta notification timing",
      emoji: null,
      isUntitled: true,
    })

    const request = parseCompletion.mock.calls[0]?.[0] as
      | {
          model?: string
          reasoning_effort?: string
          messages?: { role?: string; content?: string }[]
        }
      | undefined
    const systemMessage = request?.messages?.find((message) => message.role === "system")?.content
    const userMessage = request?.messages?.find((message) => message.role === "user")?.content

    expect(request?.model).toBe("gpt-5.6-luna")
    expect(request?.reasoning_effort).toBe("none")
    expect(systemMessage).toContain("This is a reply thread")
    expect(systemMessage).toContain("Do not prefix the title with Re: or Reply")
    expect(systemMessage).toContain("Do not choose an emoji for reply threads")
    expect(userMessage).toContain("Context type: Reply thread")
    expect(userMessage).toContain("Parent chat title: Launch planning")
    expect(userMessage).toContain("Parent chat description: Mobile beta release coordination")
    expect(userMessage).toContain("Parent message by: Mina Park")
    expect(userMessage).toContain(`Parent message: ${anchorText}`)
    expect(userMessage).toContain(
      "First eligible reply: Yes, after QA signs off on notification delivery and badge counts.",
    )

    const secondResult = await generateAndApplyThreadTitle({
      chatId: replyThread.id,
      messageId: 2,
      text: "A later reply should not regenerate the title even while untitled remains true.",
      currentUserId: user.id,
    })
    expect(secondResult.didUpdate).toBe(false)
    expect(parseCompletion).toHaveBeenCalledTimes(1)
  })

  test("does not apply a reply title after the placeholder is renamed during generation", async () => {
    let resolveCompletion: (value: ReturnType<typeof completion>) => void = () => {}
    parseCompletion.mockImplementation(
      () => new Promise<ReturnType<typeof completion>>((resolve) => { resolveCompletion = resolve }),
    )

    const user = await testUtils.createUser("reply-title-race-user@example.com")
    const parentChat = await testUtils.createChat(null, "Parent", "thread", false, user.id)
    if (!parentChat) throw new Error("Parent chat not created")

    const anchorText = "Review the new reply title behavior before launch"
    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: user.id,
      text: anchorText,
    })
    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: anchorText,
        isUntitled: true,
        publicThread: false,
        createdBy: user.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()
    if (!replyThread) throw new Error("Reply thread not created")

    const { generateAndApplyThreadTitle } = await import("@in/server/modules/threadTitles")
    const generation = generateAndApplyThreadTitle({
      chatId: replyThread.id,
      messageId: 1,
      text: "This is the first eligible reply with enough useful context.",
      currentUserId: user.id,
    })
    await waitForParseCallCount(1)

    await db
      .update(schema.chats)
      .set({ title: "Manual reply title", isUntitled: null })
      .where(eq(schema.chats.id, replyThread.id))
    resolveCompletion(completion("Generated reply title"))

    await expect(generation).resolves.toEqual({ didUpdate: false })
    const savedTitle = await db
      .select({ title: schema.chats.title })
      .from(schema.chats)
      .where(eq(schema.chats.id, replyThread.id))
      .then((rows) => rows[0]?.title)
    expect(savedTitle).toBe("Manual reply title")
  })

  test("does not overwrite a manually titled thread", async () => {
    parseCompletion.mockResolvedValue(completion("Generated Title"))

    const user = await testUtils.createUser("manual-thread-title-user@example.com")
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Manual Title",
        publicThread: false,
        createdBy: user.id,
      })
      .returning()

    if (!chat) {
      throw new Error("Chat not created")
    }

    await testUtils.addParticipant(chat.id, user.id)

    const { generateAndApplyThreadTitle } = await import("@in/server/modules/threadTitles")
    const result = await generateAndApplyThreadTitle({
      chatId: chat.id,
      messageId: 1,
      text: "Can you write the launch checklist for tomorrow morning before we send the build?",
      currentUserId: user.id,
    })

    expect(result.didUpdate).toBe(false)

    const updated = await db
      .select({ title: schema.chats.title })
      .from(schema.chats)
      .where(eq(schema.chats.id, chat.id))
      .then((rows) => rows[0])

    expect(updated?.title).toBe("Manual Title")
  })

  test("new eligible messages cancel older pending title jobs", async () => {
    let resolveFirst: (value: ReturnType<typeof completion>) => void = () => {}
    const firstCompletion = new Promise<ReturnType<typeof completion>>((resolve) => {
      resolveFirst = resolve
    })
    let calls = 0
    parseCompletion.mockImplementation(() => {
      calls += 1
      return calls === 1 ? firstCompletion : Promise.resolve(completion("Second Message Title"))
    })

    const user = await testUtils.createUser("cancel-thread-title-user@example.com")
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: user.id,
      })
      .returning()

    if (!chat) {
      throw new Error("Chat not created")
    }

    await testUtils.addParticipant(chat.id, user.id)

    const { maybeScheduleThreadTitleGeneration } = await import("@in/server/modules/threadTitles")
    maybeScheduleThreadTitleGeneration({
      chat,
      message: textMessage,
      text: "Please draft the first launch checklist for tomorrow morning before the release.",
      entities: undefined,
      currentUserId: user.id,
    })
    await waitForParseCallCount(1)

    maybeScheduleThreadTitleGeneration({
      chat,
      message: { ...textMessage, messageId: 2 },
      text: "Please draft the second launch checklist for tomorrow morning before the release.",
      entities: undefined,
      currentUserId: user.id,
    })

    await waitForChatTitle(chat.id, "Second Message Title")
    resolveFirst(completion("First Message Title"))
    await sleep(20)

    const updated = await db
      .select({ title: schema.chats.title })
      .from(schema.chats)
      .where(eq(schema.chats.id, chat.id))
      .then((rows) => rows[0])

    expect(updated?.title).toBe("Second Message Title")
  })

  test("ineligible messages do not cancel a pending title job", async () => {
    let resolveCompletion: (value: ReturnType<typeof completion>) => void = () => {}
    parseCompletion.mockImplementation(
      () => new Promise<ReturnType<typeof completion>>((resolve) => { resolveCompletion = resolve }),
    )

    const user = await testUtils.createUser("stable-pending-thread-title-user@example.com")
    const [chat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: user.id,
      })
      .returning()
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, user.id)

    const { maybeScheduleThreadTitleGeneration } = await import("@in/server/modules/threadTitles")
    maybeScheduleThreadTitleGeneration({
      chat,
      message: textMessage,
      text: "Please keep this first eligible title generation job running to completion.",
      entities: undefined,
      currentUserId: user.id,
    })
    await waitForParseCallCount(1)

    maybeScheduleThreadTitleGeneration({
      chat,
      message: { ...textMessage, messageId: 2 },
      text: "ok",
      entities: undefined,
      currentUserId: user.id,
    })

    resolveCompletion(completion("Stable pending title"))
    await waitForChatTitle(chat.id, "Stable pending title")
    expect(parseCompletion).toHaveBeenCalledTimes(1)
  })
})

async function waitForChatTitle(chatId: number, title: string) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const row = await db
      .select({ title: schema.chats.title })
      .from(schema.chats)
      .where(eq(schema.chats.id, chatId))
      .then((rows) => rows[0])

    if (row?.title === title) {
      return
    }

    await sleep(10)
  }

  throw new Error(`Timed out waiting for chat title: ${title}`)
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitForParseCallCount(count: number) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (parseCompletion.mock.calls.length >= count) {
      return
    }

    await sleep(10)
  }

  throw new Error(`Timed out waiting for ${count} title generation call(s)`)
}

function formatTestDate(timeZone: string): string {
  return new Intl.DateTimeFormat("en-US", {
    month: "long",
    day: "numeric",
    year: "numeric",
    timeZone,
  }).format(new Date())
}
