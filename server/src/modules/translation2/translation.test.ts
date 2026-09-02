import { describe, expect, mock, test } from "bun:test"
import { MessageEntity_Type } from "@inline-chat/protocol/core"

describe("Translation2.translateMessages", () => {
  test("a conflicting link cannot corrupt code or neighboring Agent identity during translation", async () => {
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe("note\n\n```ts\ncode\n```\n\n[@Maya](inline://user?id=42&agent_id=7)")
      return [{ messageId: 741, markdown: input.messages[0].markdown.replace("note", "یادداشت") }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: "note\n\ncode\n\n@Maya",
        entities: { entities: [
          { type: MessageEntity_Type.TEXT_URL, offset: 0n, length: 17n,
            entity: { oneofKind: "textUrl", textUrl: { url: "https://example.test" } } },
          { type: MessageEntity_Type.PRE, offset: 6n, length: 4n, entity: { oneofKind: "pre", pre: { language: "ts" } } },
          { type: MessageEntity_Type.MENTION, offset: 12n, length: 5n,
            entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
        ] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("یادداشت\n\ncode\n\n@Maya")
    expect(result[0]?.entities?.entities).toEqual([
      { type: MessageEntity_Type.PRE, offset: 9n, length: 4n, entity: { oneofKind: "pre", pre: { language: "ts" } } },
      { type: MessageEntity_Type.MENTION, offset: 15n, length: 5n,
        entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
    ])
  })

  test("translated group mentions retain group identity and never become user mentions", async () => {
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe("hello [@eng](inline://group/44)")
      return [{ messageId: 741, markdown: "سلام [@تیم](inline://group/44)" }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: "hello @eng",
        entities: { entities: [{ type: MessageEntity_Type.GROUP_MENTION, offset: 6n, length: 4n,
          entity: { oneofKind: "groupMention", groupMention: { groupId: 44n } } }] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("سلام @تیم")
    expect(result[0]?.entities?.entities).toEqual([{ type: MessageEntity_Type.GROUP_MENTION, offset: 5n, length: 4n,
      entity: { oneofKind: "groupMention", groupMention: { groupId: 44n } } }])
  })

  test("crossing native styles retain an intact Agent target after translation shifts offsets", async () => {
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toContain("inline://user?id=42&agent_id=7")
      return [{ messageId: 741, markdown: input.messages[0].markdown.replace("hello", "سلام") }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: "hello abMayaXY",
        entities: { entities: [
          { type: MessageEntity_Type.BOLD, offset: 6n, length: 4n, entity: { oneofKind: undefined } },
          { type: MessageEntity_Type.ITALIC, offset: 9n, length: 5n, entity: { oneofKind: undefined } },
          { type: MessageEntity_Type.MENTION, offset: 8n, length: 4n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
        ] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("سلام abMayaXY")
    const entities = result[0]!.entities!.entities
    expect(entities.filter((item) => item.type === MessageEntity_Type.MENTION)).toEqual([
      { type: MessageEntity_Type.MENTION, offset: 7n, length: 4n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
    ])
    for (const [type, start, end] of [[MessageEntity_Type.BOLD, 5, 9], [MessageEntity_Type.ITALIC, 8, 13]] as const) {
      for (let offset = 0; offset < result[0]!.translation!.length; offset++) {
        expect(entities.some((item) => item.type === type && item.offset <= BigInt(offset)
          && BigInt(offset) < item.offset + item.length)).toBe(start <= offset && offset < end)
      }
    }
  })

  test("partial formatting cannot displace PRE or corrupt its whitespace restoration", async () => {
    const translateMarkdowns = mock(async (input) => [
      { messageId: 741, markdown: input.messages[0].markdown.replace("note", "یادداشت") },
    ])
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: "note\n\ncode\n\n@Maya",
        entities: { entities: [
          { type: MessageEntity_Type.BOLD, offset: 0n, length: 8n, entity: { oneofKind: undefined } },
          { type: MessageEntity_Type.PRE, offset: 6n, length: 4n, entity: { oneofKind: "pre", pre: { language: "ts" } } },
          { type: MessageEntity_Type.MENTION, offset: 12n, length: 5n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
        ] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("یادداشت\n\ncode\n\n@Maya")
    expect(result[0]?.entities?.entities).toEqual([
      { type: MessageEntity_Type.BOLD, offset: 0n, length: 7n, entity: { oneofKind: undefined } },
      { type: MessageEntity_Type.PRE, offset: 9n, length: 4n, entity: { oneofKind: "pre", pre: { language: "ts" } } },
      { type: MessageEntity_Type.MENTION, offset: 15n, length: 5n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
    ])
  })

  test("tag fallbacks preserve native punctuation, highlighted spaces and Agent targets", async () => {
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe("hello<b>!</b><mark>  </mark>[@Maya](inline://user?id=42&agent_id=7)")
      return [{ messageId: 741, markdown: input.messages[0].markdown.replace("hello", "سلام") }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: "hello!  @Maya",
        entities: { entities: [
          { type: MessageEntity_Type.BOLD, offset: 5n, length: 1n, entity: { oneofKind: undefined } },
          { type: MessageEntity_Type.HIGHLIGHT, offset: 6n, length: 2n, entity: { oneofKind: undefined } },
          { type: MessageEntity_Type.MENTION, offset: 8n, length: 5n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
        ] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("سلام!  @Maya")
    expect(result[0]?.entities?.entities).toEqual([
      { type: MessageEntity_Type.BOLD, offset: 4n, length: 1n, entity: { oneofKind: undefined } },
      { type: MessageEntity_Type.HIGHLIGHT, offset: 5n, length: 2n, entity: { oneofKind: undefined } },
      { type: MessageEntity_Type.MENTION, offset: 7n, length: 5n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
    ])
  })

  test("literal indentation and reference-looking text survive translation with styled Agent labels", async () => {
    const text = "    hello @Maya\n\t&copy;"
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe("&#32;&#32;&#32;&#32;**hello** [@Maya](inline://user?id=42&agent_id=7)\n&#9;\\&copy;")
      return [{ messageId: 741, markdown: input.messages[0].markdown.replace("hello", "سلام") }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text,
        entities: { entities: [
          { type: MessageEntity_Type.BOLD, offset: 4n, length: 5n, entity: { oneofKind: undefined } },
          { type: MessageEntity_Type.MENTION, offset: 10n, length: 5n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
        ] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("    سلام @Maya\n\t&copy;")
    expect(result[0]?.entities?.entities).toEqual([
      { type: MessageEntity_Type.BOLD, offset: 4n, length: 4n, entity: { oneofKind: undefined } },
      { type: MessageEntity_Type.MENTION, offset: 9n, length: 5n, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
    ])
  })

  test("duplicate strikethrough stays formatting instead of erasing the translated message", async () => {
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe("~~hello~~")
      return [{ messageId: 741, markdown: input.messages[0].markdown.replace("hello", "سلام") }]
    })
    const { createTranslationModule } = await import("./translation")
    const strike = { type: MessageEntity_Type.STRIKETHROUGH, offset: 0n, length: 5n, entity: { oneofKind: undefined } }
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: "hello",
        entities: { entities: [strike, { ...strike }] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("سلام")
    expect(result[0]?.entities?.entities).toEqual([{ ...strike, length: 4n }])
  })

  test("preserves exact code and Agent ranges while translating surrounding paragraphs", async () => {
    const code = "😀 const literal = `**bold** $x$`;", prefix = "note\n\n", suffix = "\n\n@Maya"
    const text = prefix + code + suffix
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe(`note\n\n\`\`\`ts\n${code}\n\`\`\`\n\n[@Maya](inline://user?id=4&agent_id=8)`)
      return [{ messageId: 741, markdown: input.messages[0].markdown.replace("note", "یادداشت") }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text,
        entities: { entities: [
          { type: MessageEntity_Type.PRE, offset: BigInt(prefix.length), length: BigInt(code.length), entity: { oneofKind: "pre", pre: { language: "ts" } } },
          { type: MessageEntity_Type.MENTION, offset: BigInt(prefix.length + code.length + 2), length: 5n, entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } } },
        ] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    const translatedPrefix = "یادداشت\n\n"
    expect(result[0]?.translation).toBe(translatedPrefix + code + suffix)
    expect(result[0]?.entities?.entities).toEqual([
      { type: MessageEntity_Type.PRE, offset: BigInt(translatedPrefix.length), length: BigInt(code.length), entity: { oneofKind: "pre", pre: { language: "ts" } } },
      { type: MessageEntity_Type.MENTION, offset: BigInt(translatedPrefix.length + code.length + 2), length: 5n, entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } } },
    ])
  })

  test("keeps TeX source exact while translating surrounding prose", async () => {
    const source = String.raw`\frac{a_b}{c^2} + \text{**literal**}`
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe(`value $${source}$`)
      return [{ messageId: 741, markdown: `مقدار $${source}$` }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: `value ${source}`,
        entities: { entities: [{ type: MessageEntity_Type.MATH, offset: 6n, length: BigInt(source.length), entity: { oneofKind: undefined } }] },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe(`مقدار ${source}`)
    expect(result[0]?.entities?.entities).toEqual([{
      type: MessageEntity_Type.MATH, offset: 6n, length: BigInt(source.length), entity: { oneofKind: undefined },
    }])
  })

  test("retains nested v2 styles around the translated words", async () => {
    const types = [MessageEntity_Type.UNDERLINE, MessageEntity_Type.STRIKETHROUGH, MessageEntity_Type.HIGHLIGHT]
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages[0]?.markdown).toBe("<u>~~==hello==~~</u>")
      return [{ messageId: 741, markdown: "<u>~~==سلام==~~</u>" }]
    })
    const { createTranslationModule } = await import("./translation")
    const result = await createTranslationModule({ translateMarkdowns }).translateMessages({
      messages: [{
        id: 1, chatId: 10, messageId: 741, fromId: 5, date: new Date(), text: "hello",
        entities: { entities: types.map((type) => ({ type, offset: 0n, length: 5n, entity: { oneofKind: undefined } })) },
      } as any],
      language: "fa", chat: { id: 10, title: "Test chat", type: "thread" } as any, actorId: 5,
    })
    expect(result[0]?.translation).toBe("سلام")
    expect(result[0]?.entities?.entities).toEqual(types.map((type) => ({
      type, offset: 0n, length: 4n, entity: { oneofKind: undefined },
    })))
  })

  test.each([undefined, 7n])("translates markdown in one call and retains mention target %s", async (agentId) => {
    const mention = { userId: 42n, ...(agentId === undefined ? {} : { agentId }) }
    const url = agentId === undefined ? "inline://user/42" : "inline://user?id=42&agent_id=7"
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages).toHaveLength(1)
      expect(input.messages[0]?.markdown).toBe(`[hello](${url})`)
      return [{ messageId: 741, markdown: `[سلام](${url})` }]
    })

    const { createTranslationModule } = await import("./translation")
    const translationModule = createTranslationModule({
      translateMarkdowns,
    })

    const result = await translationModule.translateMessages({
      messages: [
        {
          id: 1,
          chatId: 10,
          messageId: 741,
          fromId: 5,
          date: new Date(),
          text: "hello",
          entities: {
            entities: [
              {
                type: MessageEntity_Type.MENTION,
                offset: 0n,
                length: 5n,
                entity: {
                  oneofKind: "mention",
                  mention,
                },
              },
            ],
          },
        } as any,
      ],
      language: "fa",
      chat: {
        id: 10,
        title: "Test chat",
        type: "thread",
      } as any,
      actorId: 5,
    })

    expect(translateMarkdowns).toHaveBeenCalledTimes(1)
    expect(result).toHaveLength(1)
    expect(result[0]?.messageId).toBe(741)
    expect(result[0]?.translation).toBe("سلام")
    expect(result[0]?.entities).toEqual({
      entities: [
        {
          type: MessageEntity_Type.MENTION,
          offset: 0n,
          length: 4n,
          entity: {
            oneofKind: "mention",
            mention,
          },
        },
      ],
    })
  })

  test("returns explicit empty entities when translated markdown has no entities", async () => {
    const translateMarkdowns = mock(async () => [{ messageId: 741, markdown: "سلام دنیا" }])

    const { createTranslationModule } = await import("./translation")
    const translationModule = createTranslationModule({
      translateMarkdowns,
    })

    const result = await translationModule.translateMessages({
      messages: [
        {
          id: 1,
          chatId: 10,
          messageId: 741,
          fromId: 5,
          date: new Date(),
          text: "hello world",
          entities: { entities: [] },
        } as any,
      ],
      language: "fa",
      chat: {
        id: 10,
        title: "Test chat",
        type: "thread",
      } as any,
      actorId: 5,
    })

    expect(result[0]?.translation).toBe("سلام دنیا")
    expect(result[0]?.entities).toEqual({ entities: [] })
  })
})
