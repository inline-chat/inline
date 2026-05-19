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

const completion = (title: string) => ({
  choices: [
    {
      finish_reason: "stop",
      message: {
        parsed: { title },
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
      ],
    }

    expect(
      getThreadTitleSourceText({
        chat: emptyThread,
        message: textMessage,
        text: onlyEntityText,
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
  })

  test("sets a generated title only while the thread is untitled", async () => {
    parseCompletion.mockResolvedValue(completion("Launch Checklist 🚀"))

    const user = await testUtils.createUser("thread-title-user@example.com")
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
      .select({ title: schema.chats.title })
      .from(schema.chats)
      .where(eq(schema.chats.id, chat.id))
      .then((rows) => rows[0])

    expect(updated?.title).toBe("Launch Checklist")
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
