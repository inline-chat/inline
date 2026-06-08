import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { entityPolicies, fromMd, toMd } from "."

const base = (type: MessageEntity_Type, offset: number, length: number): MessageEntity => ({
  type,
  offset: BigInt(offset),
  length: BigInt(length),
  entity: { oneofKind: undefined },
})

const pack = (entities: MessageEntity[]): MessageEntities => ({ entities })

describe("translation2 entity markdown registry", () => {
  test("has an explicit policy for every MessageEntity_Type", () => {
    const enumValues = Object.values(MessageEntity_Type).filter(
      (value): value is MessageEntity_Type => typeof value === "number",
    )

    for (const value of enumValues) {
      expect(Object.prototype.hasOwnProperty.call(entityPolicies, value)).toBe(true)
    }
  })
})

describe("translation2 entity toMd/fromMd", () => {
  test("round-trips bold, italic, code, and pre entities", () => {
    const text = "bold italic code block"
    const entities = pack([
      base(MessageEntity_Type.BOLD, 0, 4),
      base(MessageEntity_Type.ITALIC, 5, 6),
      base(MessageEntity_Type.CODE, 12, 4),
      {
        ...base(MessageEntity_Type.PRE, 17, 5),
        entity: { oneofKind: "pre", pre: { language: "ts" } },
      },
    ])

    const markdown = toMd(text, entities)
    expect(markdown).toBe("**bold** *italic* `code` ```ts\nblock```")

    const parsed = fromMd(markdown)
    expect(parsed.text).toBe(text)
    expect(parsed.entities.entities).toEqual(entities.entities)
  })

  test("round-trips text links with nested formatting", () => {
    const text = "open docs"
    const entities = pack([
      {
        ...base(MessageEntity_Type.TEXT_URL, 0, text.length),
        entity: { oneofKind: "textUrl", textUrl: { url: "https://example.com/docs" } },
      },
      base(MessageEntity_Type.BOLD, 5, 4),
    ])

    const markdown = toMd(text, entities)
    expect(markdown).toBe("[open **docs**](https://example.com/docs)")

    const parsed = fromMd(markdown)
    expect(parsed.text).toBe(text)
    expect(parsed.entities.entities).toEqual(entities.entities)
  })

  test("round-trips Inline mention and thread links", () => {
    const text = "Mo thread title"
    const entities = pack([
      {
        ...base(MessageEntity_Type.MENTION, 0, 2),
        entity: { oneofKind: "mention", mention: { userId: 42n } },
      },
      {
        ...base(MessageEntity_Type.THREAD, 3, 6),
        entity: { oneofKind: "thread", thread: { chatId: 99n } },
      },
      {
        ...base(MessageEntity_Type.THREAD_TITLE, 10, 5),
        entity: { oneofKind: "threadTitle", threadTitle: { spaceId: 7n, title: "Design" } },
      },
    ])

    const markdown = toMd(text, entities)
    expect(markdown).toBe(
      "[Mo](inline://user/42) [thread](inline://thread?id=99) [title](inline://thread?space_id=7&title=Design)",
    )

    const parsed = fromMd(markdown)
    expect(parsed.text).toBe(text)
    expect(parsed.entities.entities).toEqual(entities.entities)
  })

  test("keeps whitespace outside mention markdown labels", () => {
    const text = "@Dena  @Test2  mentions"
    const entities = pack([
      {
        ...base(MessageEntity_Type.MENTION, 0, 6),
        entity: { oneofKind: "mention", mention: { userId: 10300n } },
      },
      {
        ...base(MessageEntity_Type.MENTION, 7, 7),
        entity: { oneofKind: "mention", mention: { userId: 10600n } },
      },
    ])

    const markdown = toMd(text, entities)
    expect(markdown).toBe("[@Dena](inline://user/10300)  [@Test2](inline://user/10600)  mentions")

    const parsed = fromMd(markdown)
    expect(parsed.text).toBe(text)
    expect(parsed.entities.entities).toEqual([
      {
        type: MessageEntity_Type.MENTION,
        offset: 0n,
        length: 5n,
        entity: { oneofKind: "mention", mention: { userId: 10300n } },
      },
      {
        type: MessageEntity_Type.MENTION,
        offset: 7n,
        length: 6n,
        entity: { oneofKind: "mention", mention: { userId: 10600n } },
      },
    ])
  })

  test("trims whitespace inside parsed mention link labels", () => {
    const parsed = fromMd("[@Dena ](inline://user/10300)  [@Test2 ](inline://user/10600) , two mentions")

    expect(parsed.text).toBe("@Dena   @Test2  , two mentions")
    expect(parsed.entities.entities).toEqual([
      {
        type: MessageEntity_Type.MENTION,
        offset: 0n,
        length: 5n,
        entity: { oneofKind: "mention", mention: { userId: 10300n } },
      },
      {
        type: MessageEntity_Type.MENTION,
        offset: 8n,
        length: 6n,
        entity: { oneofKind: "mention", mention: { userId: 10600n } },
      },
    ])
  })

  test("round-trips thread links whose visible label includes double brackets", () => {
    const text = "Open [[Planning]] now"
    const entities = pack([
      {
        ...base(MessageEntity_Type.THREAD, 5, 12),
        entity: { oneofKind: "thread", thread: { chatId: 42n } },
      },
    ])

    const markdown = toMd(text, entities)
    expect(markdown).toBe("Open [\\[\\[Planning\\]\\]](inline://thread?id=42) now")

    const parsed = fromMd(markdown)
    expect(parsed.text).toBe(text)
    expect(parsed.entities.entities).toEqual(entities.entities)
  })

  test("parses raw double-bracket thread link labels from model output", () => {
    const parsed = fromMd("Open [[Project **Plan**]](inline://thread?space_id=7&title=Project%20Plan) now")

    expect(parsed.text).toBe("Open [[Project Plan]] now")
    expect(parsed.entities.entities).toEqual([
      {
        type: MessageEntity_Type.THREAD_TITLE,
        offset: 5n,
        length: 16n,
        entity: {
          oneofKind: "threadTitle",
          threadTitle: {
            spaceId: 7n,
            title: "Project Plan",
          },
        },
      },
      {
        type: MessageEntity_Type.BOLD,
        offset: 15n,
        length: 4n,
        entity: { oneofKind: undefined },
      },
    ])
  })

  test("parses hashtag-looking labels inside thread links", () => {
    const parsed = fromMd("Open [#thread](inline://thread?space_id=7&title=%23thread) now")

    expect(parsed.text).toBe("Open #thread now")
    expect(parsed.entities.entities).toEqual([
      {
        type: MessageEntity_Type.THREAD_TITLE,
        offset: 5n,
        length: 7n,
        entity: {
          oneofKind: "threadTitle",
          threadTitle: {
            spaceId: 7n,
            title: "#thread",
          },
        },
      },
    ])
  })

  test("keeps UTF-16 offsets stable around emoji", () => {
    const prefix = "😀 hi "
    const text = `${prefix}Mo`
    const entities = pack([
      {
        ...base(MessageEntity_Type.MENTION, prefix.length, 2),
        entity: { oneofKind: "mention", mention: { userId: 42n } },
      },
    ])

    expect(prefix.length).toBe(6)

    const markdown = toMd(text, entities)
    expect(markdown).toBe("😀 hi [Mo](inline://user/42)")

    const parsed = fromMd(markdown)
    expect(parsed.text).toBe(text)
    expect(parsed.entities.entities).toEqual(entities.entities)
  })

  test("escapes markdown control characters in literal text", () => {
    const text = "literal * [x](y) _ok_ `code`"
    const markdown = toMd(text, undefined)

    expect(markdown).toBe("literal \\* \\[x\\]\\(y\\) \\_ok\\_ \\`code\\`")
    expect(fromMd(markdown).text).toBe(text)
    expect(fromMd(markdown).entities.entities).toEqual([])
  })

  test("detects literal entities after markdown parsing", () => {
    const parsed = fromMd("Email a@b.com, visit https://inline.chat, run /start, ping @mo, call +1 555 123 4567")
    const types = parsed.entities.entities.map((entity) => entity.type)

    expect(types).toContain(MessageEntity_Type.EMAIL)
    expect(types).toContain(MessageEntity_Type.URL)
    expect(types).toContain(MessageEntity_Type.BOT_COMMAND)
    expect(types).toContain(MessageEntity_Type.USERNAME_MENTION)
    expect(types).toContain(MessageEntity_Type.PHONE_NUMBER)
  })

  test("does not detect literal entities inside code", () => {
    const parsed = fromMd("`Email a@b.com and run /start`")

    expect(parsed.text).toBe("Email a@b.com and run /start")
    expect(parsed.entities.entities).toEqual([
      {
        type: MessageEntity_Type.CODE,
        offset: 0n,
        length: 28n,
        entity: { oneofKind: undefined },
      },
    ])
  })

  test("drops entities when translated markdown omits formatting", () => {
    const parsed = fromMd("bonjour monde")

    expect(parsed.text).toBe("bonjour monde")
    expect(parsed.entities.entities).toEqual([])
  })
})
