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
  parentChatId: null,
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
      | { messages?: { role?: string; content?: string }[] }
      | undefined
    const systemMessage = request?.messages?.find((message) => message.role === "system")?.content
    expect(systemMessage).toContain("roughly half of the time")
    expect(systemMessage).toContain("Default to sentence casing")
    expect(systemMessage).toContain("If the messages themselves are all lowercase")
    expect(systemMessage).toContain("Prefer 3-10 title words")
    expect(systemMessage).toContain("allow a longer title")
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
