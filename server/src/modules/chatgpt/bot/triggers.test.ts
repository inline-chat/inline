import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type InputPeer, type MessageEntities } from "@inline-chat/protocol/core"
import type { DbChat, DbMessage } from "@in/server/db/schema"
import { buildChatgptRunKey, detectChatgptTrigger } from "./triggers"

const inputPeer: InputPeer = {
  type: { oneofKind: "chat", chat: { chatId: 100n } },
}

describe("chatgpt bot triggers", () => {
  test("builds stable run keys per chat, thread, and actor", () => {
    expect(buildChatgptRunKey({ chatId: 1, actorUserId: 2 })).toBe("chatgpt:1:main:2")
    expect(buildChatgptRunKey({ chatId: 1, threadRootMsgId: 9, actorUserId: 2 })).toBe("chatgpt:1:9:2")
  })

  test("triggers in direct messages with the official bot", async () => {
    const trigger = await detectChatgptTrigger({
      chat: privateChat(),
      message: message(),
      text: "hello",
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
    })

    expect(trigger).toMatchObject({
      kind: "message",
      reason: "dm",
      runKey: "chatgpt:100:main:10",
    })
  })

  test("triggers on all ChatGPT aliases in normal message text", async () => {
    for (const alias of ["@chat", "@chatgpt", "@gpt", "@GPT"]) {
      const trigger = await detectChatgptTrigger({
        chat: groupChat(),
        message: message(),
        text: `${alias} summarize this`,
        inputPeer,
        actorUserId: 10,
        botUserId: 42,
      })

      expect(trigger).toMatchObject({
        kind: "message",
        reason: "mention",
        alias: alias.replace(/^@/, "").toLowerCase(),
      })
    }
  })

  test("triggers on canonical mention entities", async () => {
    const trigger = await detectChatgptTrigger({
      chat: groupChat(),
      message: message(),
      text: "hello @chatgpt",
      entities: mentionEntity("hello @chatgpt", "@chatgpt"),
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
    })

    expect(trigger).toMatchObject({
      kind: "message",
      reason: "mention",
      alias: "chatgpt",
    })
  })

  test("triggers on direct replies to bot messages without repeated mentions", async () => {
    const trigger = await detectChatgptTrigger({
      chat: groupChat(),
      message: message({ replyToMsgId: 9 }),
      text: "yes, continue",
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
      lookups: {
        isReplyToBot: async ({ messageId, botUserId }) => messageId === 9 && botUserId === 42,
      },
    })

    expect(trigger).toMatchObject({
      kind: "message",
      reason: "reply",
      runKey: "chatgpt:100:main:10",
    })
  })

  test("triggers in reply threads anchored to ChatGPT without repeated mentions", async () => {
    const trigger = await detectChatgptTrigger({
      chat: replyThreadChat(),
      message: message(),
      text: "continue in this thread",
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
      lookups: {
        isThreadRootFromBot: async ({ chat, botUserId }) => chat.parentMessageId === 7 && botUserId === 42,
      },
    })

    expect(trigger).toMatchObject({
      kind: "message",
      reason: "thread",
      runKey: "chatgpt:100:7:10",
    })
  })

  test("handles suffixed stop commands and bare stop in direct messages", async () => {
    const suffixed = await detectChatgptTrigger({
      chat: groupChat(),
      message: message(),
      text: "/stop@gpt",
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
    })
    const bare = await detectChatgptTrigger({
      chat: privateChat(),
      message: message(),
      text: "/stop",
      entities: botCommandEntity("/stop"),
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
    })

    expect(suffixed).toMatchObject({ kind: "stop", runKey: "chatgpt:100:main:10" })
    expect(bare).toMatchObject({ kind: "stop", runKey: "chatgpt:100:main:10" })
  })

  test("allows bare stop in reply threads anchored to ChatGPT", async () => {
    const trigger = await detectChatgptTrigger({
      chat: replyThreadChat(),
      message: message(),
      text: "/stop",
      entities: botCommandEntity("/stop"),
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
      lookups: {
        isThreadRootFromBot: async () => true,
      },
    })

    expect(trigger).toMatchObject({ kind: "stop", runKey: "chatgpt:100:7:10" })
  })

  test("ignores messages sent by the official bot", async () => {
    const trigger = await detectChatgptTrigger({
      chat: privateChat(),
      message: message({ fromId: 42 }),
      text: "@gpt hello",
      inputPeer,
      actorUserId: 10,
      botUserId: 42,
    })

    expect(trigger).toBeUndefined()
  })
})

function privateChat(): DbChat {
  return {
    id: 100,
    type: "private",
    minUserId: 10,
    maxUserId: 42,
    parentMessageId: null,
  } as DbChat
}

function groupChat(): DbChat {
  return {
    id: 100,
    type: "thread",
    minUserId: null,
    maxUserId: null,
    parentMessageId: null,
  } as DbChat
}

function replyThreadChat(): DbChat {
  return {
    id: 100,
    type: "thread",
    minUserId: null,
    maxUserId: null,
    parentChatId: 99,
    parentMessageId: 7,
  } as DbChat
}

function message(overrides: Partial<DbMessage> = {}): DbMessage {
  return {
    id: 5,
    fromId: 10,
    replyToMsgId: null,
    ...overrides,
  } as DbMessage
}

function mentionEntity(text: string, mention: string): MessageEntities {
  const offset = text.indexOf(mention)
  return {
    entities: [
      {
        type: MessageEntity_Type.MENTION,
        offset: BigInt(offset),
        length: BigInt(mention.length),
        entity: { oneofKind: "mention", mention: { userId: 42n } },
      },
    ],
  }
}

function botCommandEntity(command: string): MessageEntities {
  return {
    entities: [
      {
        type: MessageEntity_Type.BOT_COMMAND,
        offset: 0n,
        length: BigInt(command.length),
        entity: { oneofKind: undefined },
      },
    ],
  }
}
