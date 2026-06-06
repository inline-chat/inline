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
  })

  test("preserves existing text link aliases", () => {
    const entities = parseBotEntities([
      { type: "text_url", offset: 0, length: 4, url: "https://inline.chat" },
    ])

    expect(entities?.entities[0]?.type).toBe(MessageEntity_Type.TEXT_URL)
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
})
