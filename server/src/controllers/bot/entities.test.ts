import { describe, expect, test } from "bun:test"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { encodeBotEntities, parseBotEntities } from "./entities"

describe("bot entities", () => {
  test("round-trips range-only v2 styles without payload fields", () => {
    const input = (["underline", "strikethrough", "highlight"] as const).map((type) => ({ type, offset: 3, length: 5 }))
    const parsed = parseBotEntities(input)
    expect(parsed?.entities.map((entity) => entity.type)).toEqual([
      MessageEntity_Type.UNDERLINE, MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT,
    ])
    expect(parsed?.entities.every((entity) => entity.entity.oneofKind === undefined)).toBe(true)
    expect(encodeBotEntities(parsed)).toEqual(input)
  })

  test("parses thread entities", () => {
    const entities = parseBotEntities([
      {
        type: "thread",
        offset: 0,
        length: 13,
        chat_id: "42",
      },
      {
        type: "thread_title",
        offset: 18,
        length: 12,
        space_id: "7",
        title: " Planning ",
      },
    ])

    expect(entities?.entities).toHaveLength(2)

    const thread = entities!.entities[0]!
    expect(thread.type).toBe(MessageEntity_Type.THREAD)
    expect(thread.entity.oneofKind).toBe("thread")
    if (thread.entity.oneofKind !== "thread") throw new Error("Expected thread entity")
    expect(thread.entity.thread.chatId).toBe(42n)

    const title = entities!.entities[1]!
    expect(title.type).toBe(MessageEntity_Type.THREAD_TITLE)
    expect(title.entity.oneofKind).toBe("threadTitle")
    if (title.entity.oneofKind !== "threadTitle") throw new Error("Expected thread title entity")
    expect(title.entity.threadTitle.spaceId).toBe(7n)
    expect(title.entity.threadTitle.title).toBe("Planning")
  })

  test("parses home thread title entities without a space id", () => {
    const entities = parseBotEntities([
      {
        type: "thread_title",
        offset: 0,
        length: 12,
        title: "Personal",
      },
    ])

    const title = entities?.entities[0]
    expect(title?.type).toBe(MessageEntity_Type.THREAD_TITLE)
    expect(title?.entity.oneofKind).toBe("threadTitle")
    if (title?.entity.oneofKind !== "threadTitle") throw new Error("Expected thread title entity")
    expect(title.entity.threadTitle.spaceId).toBe(0n)
    expect(title.entity.threadTitle.title).toBe("Personal")
  })

  test("rejects non-canonical thread entity names and fields", () => {
    expect(() => parseBotEntities([
      { type: "threadlink", offset: 0, length: 7, chat_id: "42" },
    ])).toThrow()

    expect(() => parseBotEntities([
      { type: "thread", offset: 0, length: 7, thread_id: "42" },
    ])).toThrow()

    expect(() => parseBotEntities([
      { type: "thread_title_link", offset: 0, length: 12, space_id: "7", title: "Planning" },
    ])).toThrow()
  })

  test("rejects non-canonical entity type formats", () => {
    expect(() => parseBotEntities([
      { type: "TYPE_THREAD", offset: 0, length: 7, chat_id: "42" },
    ])).toThrow()

    expect(() => parseBotEntities([
      { type: 11, offset: 0, length: 7, chat_id: "42" },
    ])).toThrow()
  })

  test("preserves existing text link aliases", () => {
    const entities = parseBotEntities([
      { type: "text_url", offset: 0, length: 4, url: "https://inline.chat" },
    ])

    expect(entities?.entities[0]?.type).toBe(MessageEntity_Type.TEXT_URL)
  })

  test("parses bot command entities", () => {
    const entities = parseBotEntities([
      { type: "bot_command", offset: 0, length: 6 },
    ])

    expect(entities?.entities).toHaveLength(1)
    const command = entities!.entities[0]!
    expect(command.type).toBe(MessageEntity_Type.BOT_COMMAND)
    expect(command.entity.oneofKind).toBeUndefined()
  })

  test("encodes thread entities", () => {
    const encoded = encodeBotEntities({
      entities: [
        {
          type: MessageEntity_Type.THREAD,
          offset: 0n,
          length: 13n,
          entity: {
            oneofKind: "thread",
            thread: { chatId: 42n },
          },
        },
        {
          type: MessageEntity_Type.THREAD_TITLE,
          offset: 18n,
          length: 12n,
          entity: {
            oneofKind: "threadTitle",
            threadTitle: { spaceId: 7n, title: "Planning" },
          },
        },
      ],
    })

    expect(encoded).toEqual([
      {
        type: "thread",
        offset: 0,
        length: 13,
        chat_id: 42,
      },
      {
        type: "thread_title",
        offset: 18,
        length: 12,
        space_id: 7,
        title: "Planning",
      },
    ])
  })

  test("omits space id when encoding home thread title entities", () => {
    const encoded = encodeBotEntities({
      entities: [
        {
          type: MessageEntity_Type.THREAD_TITLE,
          offset: 0n,
          length: 8n,
          entity: {
            oneofKind: "threadTitle",
            threadTitle: { spaceId: 0n, title: "Personal" },
          },
        },
      ],
    })

    expect(encoded).toEqual([
      {
        type: "thread_title",
        offset: 0,
        length: 8,
        title: "Personal",
      },
    ])
  })

  test("encodes bot command entities", () => {
    const encoded = encodeBotEntities({
      entities: [
        {
          type: MessageEntity_Type.BOT_COMMAND,
          offset: 0n,
          length: 6n,
          entity: { oneofKind: undefined },
        },
      ],
    })

    expect(encoded).toEqual([
      {
        type: "bot_command",
        offset: 0,
        length: 6,
      },
    ])
  })

  test("encodes the Agent id beside the backing bot mention", () => {
    const encoded = encodeBotEntities({
      entities: [{
        type: MessageEntity_Type.MENTION,
        offset: 0n,
        length: 12n,
        entity: {
          oneofKind: "mention",
          mention: { userId: 20n, agentId: 73n },
        },
      }],
    }, {
      usersById: new Map([[20, { id: 20, is_bot: true, first_name: "Host Bot" }]]),
    })

    expect(encoded).toEqual([{
      type: "text_mention",
      offset: 0,
      length: 12,
      user: { id: 20, is_bot: true, first_name: "Host Bot" },
      agent_id: 73,
    }])
  })
})
