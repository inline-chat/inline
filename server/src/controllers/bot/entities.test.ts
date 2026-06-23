import { describe, expect, test } from "bun:test"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { encodeBotEntities, parseBotEntities } from "./entities"

describe("bot entities", () => {
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

    expect(() => parseBotEntities([
      { type: 999, offset: 0, length: 7 },
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

  test("parses blockquote entities", () => {
    const entities = parseBotEntities([
      { type: "blockquote", offset: 0, length: 6 },
      { type: "expandable_blockquote", offset: 7, length: 8 },
    ], { text: "quoted expanded" })

    expect(entities?.entities.map((entity) => entity.type)).toEqual([
      MessageEntity_Type.BLOCKQUOTE,
      MessageEntity_Type.EXPANDABLE_BLOCKQUOTE,
    ])
    expect(entities?.entities.every((entity) => entity.entity.oneofKind === undefined)).toBe(true)

    expect(() => parseBotEntities([
      { type: 16, offset: 0, length: 6 },
    ], { text: "quoted" })).toThrow()
  })

  test("validates ranges against UTF-16 text length", () => {
    const entities = parseBotEntities([
      { type: "bold", offset: 1, length: 2 },
    ], { text: "A😀B" })

    expect(entities?.entities[0]?.offset).toBe(1n)
    expect(entities?.entities[0]?.length).toBe(2n)

    expect(() => parseBotEntities([
      { type: "bold", offset: 4, length: 1 },
    ], { text: "A😀B" })).toThrow()

    expect(() => parseBotEntities([
      { type: "bold", offset: 2, length: 1 },
    ], { text: "A😀B" })).toThrow()

    expect(() => parseBotEntities([
      { type: "bold", offset: 1, length: 1 },
    ], { text: "A😀B" })).toThrow()

    expect(() => parseBotEntities([
      { type: "bold", offset: -1, length: 1 },
    ], { text: "abc" })).toThrow()

    expect(() => parseBotEntities([
      { type: "bold", offset: 0, length: 0 },
    ], { text: "abc" })).toThrow()

    expect(() => parseBotEntities([
      { type: "bold", offset: 0.5, length: 1 },
    ], { text: "abc" })).toThrow()
  })

  test("allows Telegram-compatible style nesting around non-style entities", () => {
    const entities = parseBotEntities([
      { type: "bold", offset: 0, length: 11 },
      { type: "text_link", offset: 6, length: 5, url: "https://inline.chat" },
      { type: "underline", offset: 6, length: 5 },
    ], { text: "hello world" })

    expect(entities?.entities.map((entity) => entity.type)).toEqual([
      MessageEntity_Type.BOLD,
      MessageEntity_Type.TEXT_URL,
      MessageEntity_Type.UNDERLINE,
    ])
  })

  test("rejects partially overlapping entities", () => {
    expect(() => parseBotEntities([
      { type: "bold", offset: 0, length: 5 },
      { type: "italic", offset: 3, length: 5 },
    ], { text: "hello world" })).toThrow()
  })

  test("rejects code and pre overlap with any entity", () => {
    expect(() => parseBotEntities([
      { type: "code", offset: 0, length: 4 },
      { type: "bold", offset: 0, length: 4 },
    ], { text: "code text" })).toThrow()

    expect(() => parseBotEntities([
      { type: "pre", offset: 0, length: 9, language: "ts" },
      { type: "italic", offset: 2, length: 4 },
    ], { text: "code text" })).toThrow()
  })

  test("rejects overlapping non-style entities even when nested", () => {
    expect(() => parseBotEntities([
      { type: "url", offset: 0, length: 11 },
      { type: "text_link", offset: 6, length: 5, url: "https://inline.chat" },
    ], { text: "hello world" })).toThrow()
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

  test("encodes blockquote entities", () => {
    const encoded = encodeBotEntities({
      entities: [
        {
          type: MessageEntity_Type.BLOCKQUOTE,
          offset: 0n,
          length: 6n,
          entity: { oneofKind: undefined },
        },
        {
          type: MessageEntity_Type.EXPANDABLE_BLOCKQUOTE,
          offset: 7n,
          length: 8n,
          entity: { oneofKind: undefined },
        },
      ],
    })

    expect(encoded).toEqual([
      {
        type: "blockquote",
        offset: 0,
        length: 6,
      },
      {
        type: "expandable_blockquote",
        offset: 7,
        length: 8,
      },
    ])
  })
})
