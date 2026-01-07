import { describe, test, expect } from "bun:test"
import { processMessageText } from "./processText"
import { parseMarkdown } from "./parseMarkdown"
import { MessageEntity_Type } from "@in/protocol/core"

describe("parseMarkdown", () => {
  describe("basic patterns", () => {
    test("bold with asterisks", () => {
      const result = parseMarkdown("Hello **world**")
      expect(result.text).toBe("Hello world")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(6),
        length: BigInt(5),
        type: MessageEntity_Type.BOLD,
      })
    })

    test("bold with underscores", () => {
      const result = parseMarkdown("Hello __world__")
      expect(result.text).toBe("Hello world")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(6),
        length: BigInt(5),
        type: MessageEntity_Type.BOLD,
      })
    })

    test("italic with asterisk", () => {
      const result = parseMarkdown("Hello *world*")
      expect(result.text).toBe("Hello world")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(6),
        length: BigInt(5),
        type: MessageEntity_Type.ITALIC,
      })
    })

    test("italic with underscore", () => {
      const result = parseMarkdown("Hello _world_")
      expect(result.text).toBe("Hello world")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(6),
        length: BigInt(5),
        type: MessageEntity_Type.ITALIC,
      })
    })

    test("inline code", () => {
      const result = parseMarkdown("Use `code` here")
      expect(result.text).toBe("Use code here")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(4),
        length: BigInt(4),
        type: MessageEntity_Type.CODE,
      })
    })

    test("link", () => {
      const result = parseMarkdown("[click](https://example.com)")
      expect(result.text).toBe("click")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(0),
        length: BigInt(5),
        type: MessageEntity_Type.TEXT_URL,
      })
      expect(result.entities[0]!.entity).toEqual({
        oneofKind: "textUrl",
        textUrl: { url: "https://example.com" },
      })
    })

    test("email", () => {
      const result = parseMarkdown("Reach me at test@example.com")
      expect(result.text).toBe("Reach me at test@example.com")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(12),
        length: BigInt(16),
        type: MessageEntity_Type.EMAIL,
      })
    })
  })

  describe("code blocks", () => {
    test("code block with language", () => {
      const result = parseMarkdown("```js\nconsole.log('hi')\n```")
      expect(result.text).toBe("console.log('hi')")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(0),
        length: BigInt(17),
        type: MessageEntity_Type.PRE,
      })
      expect(result.entities[0]!.entity).toEqual({
        oneofKind: "pre",
        pre: { language: "js" },
      })
    })

    test("code block without language", () => {
      const result = parseMarkdown("```\ncode here\n```")
      expect(result.text).toBe("code here")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(0),
        length: BigInt(9),
        type: MessageEntity_Type.PRE,
      })
      expect(result.entities[0]!.entity).toEqual({
        oneofKind: "pre",
        pre: { language: "" },
      })
    })

    test("multiline code block", () => {
      const result = parseMarkdown("```python\nline1\nline2\nline3\n```")
      expect(result.text).toBe("line1\nline2\nline3")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        type: MessageEntity_Type.PRE,
      })
    })

    test("code block preserves content without parsing markdown inside", () => {
      const result = parseMarkdown("```\n**not bold** *not italic*\n```")
      expect(result.text).toBe("**not bold** *not italic*")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]!.type).toBe(MessageEntity_Type.PRE)
    })

    test("code block with text before and after", () => {
      const result = parseMarkdown("Before\n```js\ncode\n```\nAfter")
      expect(result.text).toBe("Before\ncode\nAfter")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(7),
        length: BigInt(4),
        type: MessageEntity_Type.PRE,
      })
    })

    test("multiple code blocks", () => {
      const result = parseMarkdown("```js\nfirst\n```\ntext\n```py\nsecond\n```")
      expect(result.text).toBe("first\ntext\nsecond")
      expect(result.entities).toHaveLength(2)
      expect(result.entities[0]!.entity).toEqual({
        oneofKind: "pre",
        pre: { language: "js" },
      })
      expect(result.entities[1]!.entity).toEqual({
        oneofKind: "pre",
        pre: { language: "py" },
      })
    })

    test("code block with various languages", () => {
      const languages = ["typescript", "python", "rust", "go", "swift"]
      for (const lang of languages) {
        const result = parseMarkdown("```" + lang + "\ncode\n```")
        expect(result.entities[0]!.entity).toEqual({
          oneofKind: "pre",
          pre: { language: lang },
        })
      }
    })

    test("unclosed code block is left unchanged", () => {
      const result = parseMarkdown("```js\ncode without closing")
      expect(result.text).toBe("```js\ncode without closing")
      expect(result.entities).toHaveLength(0)
    })

    test("code block with empty content", () => {
      const result = parseMarkdown("```\n\n```")
      expect(result.text).toBe("")
      expect(result.entities).toHaveLength(0)
    })

    test("code block preserves indentation", () => {
      const result = parseMarkdown("```\n  indented\n    more\n```")
      expect(result.text).toBe("indented\n    more")
      expect(result.entities).toHaveLength(1)
    })
  })

  describe("inline code edge cases", () => {
    test("inline code at start of text", () => {
      const result = parseMarkdown("`code` at start")
      expect(result.text).toBe("code at start")
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(0),
        length: BigInt(4),
        type: MessageEntity_Type.CODE,
      })
    })

    test("inline code at end of text", () => {
      const result = parseMarkdown("ends with `code`")
      expect(result.text).toBe("ends with code")
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(10),
        length: BigInt(4),
        type: MessageEntity_Type.CODE,
      })
    })

    test("multiple inline codes", () => {
      const result = parseMarkdown("`first` and `second` and `third`")
      expect(result.text).toBe("first and second and third")
      expect(result.entities).toHaveLength(3)
      expect(result.entities[0]).toMatchObject({ offset: BigInt(0), length: BigInt(5) })
      expect(result.entities[1]).toMatchObject({ offset: BigInt(10), length: BigInt(6) })
      expect(result.entities[2]).toMatchObject({ offset: BigInt(21), length: BigInt(5) })
    })

    test("inline code with special characters", () => {
      const result = parseMarkdown("`const x = 1 + 2;`")
      expect(result.text).toBe("const x = 1 + 2;")
      expect(result.entities).toHaveLength(1)
    })

    test("inline code preserves markdown-like content", () => {
      const result = parseMarkdown("`**not bold**`")
      expect(result.text).toBe("**not bold**")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]!.type).toBe(MessageEntity_Type.CODE)
    })

    test("inline code with spaces", () => {
      const result = parseMarkdown("`code with spaces`")
      expect(result.text).toBe("code with spaces")
      expect(result.entities[0]).toMatchObject({
        length: BigInt(16),
      })
    })

    test("adjacent inline codes", () => {
      const result = parseMarkdown("`one``two`")
      expect(result.text).toBe("onetwo")
      expect(result.entities).toHaveLength(2)
    })

    test("unclosed inline code is left unchanged", () => {
      const result = parseMarkdown("unclosed `code here")
      expect(result.text).toBe("unclosed `code here")
      expect(result.entities).toHaveLength(0)
    })

    test("empty backticks are left unchanged", () => {
      const result = parseMarkdown("empty `` backticks")
      expect(result.text).toBe("empty `` backticks")
      expect(result.entities).toHaveLength(0)
    })

    test("inline code mixed with other formatting", () => {
      const result = parseMarkdown("**bold** then `code` then *italic*")
      expect(result.text).toBe("bold then code then italic")
      expect(result.entities).toHaveLength(3)
      expect(result.entities[0]!.type).toBe(MessageEntity_Type.BOLD)
      expect(result.entities[1]!.type).toBe(MessageEntity_Type.CODE)
      expect(result.entities[2]!.type).toBe(MessageEntity_Type.ITALIC)
    })

    test("inline code inside link text is not parsed as link", () => {
      const result = parseMarkdown("`[not a link](url)`")
      expect(result.text).toBe("[not a link](url)")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]!.type).toBe(MessageEntity_Type.CODE)
    })
  })

  describe("multiple entities", () => {
    test("bold and italic", () => {
      const result = parseMarkdown("**bold** and *italic*")
      expect(result.text).toBe("bold and italic")
      expect(result.entities).toHaveLength(2)
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(0),
        length: BigInt(4),
        type: MessageEntity_Type.BOLD,
      })
      expect(result.entities[1]).toMatchObject({
        offset: BigInt(9),
        length: BigInt(6),
        type: MessageEntity_Type.ITALIC,
      })
    })

    test("multiple entities with correct offsets after removal", () => {
      const result = parseMarkdown("Start **bold** middle *italic* end")
      expect(result.text).toBe("Start bold middle italic end")
      expect(result.entities).toHaveLength(2)
      // "Start " = 6, "bold" = 4
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(6),
        length: BigInt(4),
        type: MessageEntity_Type.BOLD,
      })
      // "Start bold middle " = 18, "italic" = 6
      expect(result.entities[1]).toMatchObject({
        offset: BigInt(18),
        length: BigInt(6),
        type: MessageEntity_Type.ITALIC,
      })
    })

    test("code and link together", () => {
      const result = parseMarkdown("Use `code` and [link](url)")
      expect(result.text).toBe("Use code and link")
      expect(result.entities).toHaveLength(2)
    })
  })

  describe("edge cases", () => {
    test("plain text returns no entities", () => {
      const result = parseMarkdown("Hello world")
      expect(result.text).toBe("Hello world")
      expect(result.entities).toHaveLength(0)
    })

    test("empty string", () => {
      const result = parseMarkdown("")
      expect(result.text).toBe("")
      expect(result.entities).toHaveLength(0)
    })

    test("unclosed bold is left unchanged", () => {
      const result = parseMarkdown("Hello **world")
      expect(result.text).toBe("Hello **world")
      expect(result.entities).toHaveLength(0)
    })

    test("unclosed italic is left unchanged", () => {
      const result = parseMarkdown("Hello *world")
      expect(result.text).toBe("Hello *world")
      expect(result.entities).toHaveLength(0)
    })

    test("unclosed code is left unchanged", () => {
      const result = parseMarkdown("Hello `world")
      expect(result.text).toBe("Hello `world")
      expect(result.entities).toHaveLength(0)
    })

    test("plain URL is unchanged (not a markdown link)", () => {
      const result = parseMarkdown("Visit https://example.com today")
      expect(result.text).toBe("Visit https://example.com today")
      expect(result.entities).toHaveLength(0)
    })

    test("entity at start of string", () => {
      const result = parseMarkdown("**bold** text")
      expect(result.text).toBe("bold text")
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(0),
        length: BigInt(4),
      })
    })

    test("entity at end of string", () => {
      const result = parseMarkdown("text **bold**")
      expect(result.text).toBe("text bold")
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(5),
        length: BigInt(4),
      })
    })

    test("only markdown with no surrounding text", () => {
      const result = parseMarkdown("**bold**")
      expect(result.text).toBe("bold")
      expect(result.entities).toHaveLength(1)
    })
  })

  describe("entity offset correctness", () => {
    // These tests verify that entity offsets point to the correct content
    // in the OUTPUT text, not the input text. This catches bugs where
    // offsets are calculated against intermediate text states.

    function verifyEntityContent(text: string, entity: { offset: bigint; length: bigint }, expected: string) {
      const start = Number(entity.offset)
      const len = Number(entity.length)
      const actual = text.slice(start, start + len)
      expect(actual).toBe(expected)
    }

    test("single bold entity offset is correct", () => {
      const result = parseMarkdown("Hello **world**")
      expect(result.entities).toHaveLength(1)
      verifyEntityContent(result.text, result.entities[0]!, "world")
    })

    test("entity after removed syntax has correct offset", () => {
      // The **bold** removes 4 chars, so subsequent offsets must account for this
      const result = parseMarkdown("**bold** then `code`")
      expect(result.entities).toHaveLength(2)
      verifyEntityContent(result.text, result.entities[0]!, "bold")
      verifyEntityContent(result.text, result.entities[1]!, "code")
    })

    test("multiple entities all have correct offsets", () => {
      const result = parseMarkdown("**a** *b* `c` [d](url)")
      expect(result.entities).toHaveLength(4)
      verifyEntityContent(result.text, result.entities[0]!, "a")
      verifyEntityContent(result.text, result.entities[1]!, "b")
      verifyEntityContent(result.text, result.entities[2]!, "c")
      verifyEntityContent(result.text, result.entities[3]!, "d")
    })

    test("code block followed by inline code has correct offsets", () => {
      const input = "```js\nfoo\n```\nbar `baz`"
      const result = parseMarkdown(input)
      // Code block should produce entity for "foo", inline code for "baz"
      expect(result.text).toBe("foo\nbar baz")
      expect(result.entities).toHaveLength(2)
      verifyEntityContent(result.text, result.entities[0]!, "foo")
      verifyEntityContent(result.text, result.entities[1]!, "baz")
    })

    test("inline code followed by bold has correct offsets", () => {
      const result = parseMarkdown("`code` and **bold**")
      expect(result.entities).toHaveLength(2)
      verifyEntityContent(result.text, result.entities[0]!, "code")
      verifyEntityContent(result.text, result.entities[1]!, "bold")
    })

    test("link followed by italic has correct offsets", () => {
      const result = parseMarkdown("[link](url) and *italic*")
      expect(result.entities).toHaveLength(2)
      verifyEntityContent(result.text, result.entities[0]!, "link")
      verifyEntityContent(result.text, result.entities[1]!, "italic")
    })

    test("many entities in sequence all have correct offsets", () => {
      const result = parseMarkdown("**1** *2* `3` **4** *5* `6`")
      expect(result.entities).toHaveLength(6)
      verifyEntityContent(result.text, result.entities[0]!, "1")
      verifyEntityContent(result.text, result.entities[1]!, "2")
      verifyEntityContent(result.text, result.entities[2]!, "3")
      verifyEntityContent(result.text, result.entities[3]!, "4")
      verifyEntityContent(result.text, result.entities[4]!, "5")
      verifyEntityContent(result.text, result.entities[5]!, "6")
    })

    test("entities with multiline content have correct offsets", () => {
      const result = parseMarkdown("start\n```\nline1\nline2\n```\nend `code`")
      expect(result.entities).toHaveLength(2)
      verifyEntityContent(result.text, result.entities[0]!, "line1\nline2")
      verifyEntityContent(result.text, result.entities[1]!, "code")
    })

    test("entity at very end has correct offset", () => {
      const result = parseMarkdown("text **bold**")
      verifyEntityContent(result.text, result.entities[0]!, "bold")
      expect(Number(result.entities[0]!.offset) + Number(result.entities[0]!.length)).toBe(result.text.length)
    })

    test("entity at very start has offset 0", () => {
      const result = parseMarkdown("**bold** text")
      expect(result.entities[0]!.offset).toBe(BigInt(0))
      verifyEntityContent(result.text, result.entities[0]!, "bold")
    })

    test("long text with entity in middle has correct offset", () => {
      const prefix = "a".repeat(100)
      const suffix = "b".repeat(100)
      const result = parseMarkdown(`${prefix}**bold**${suffix}`)
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]!.offset).toBe(BigInt(100))
      verifyEntityContent(result.text, result.entities[0]!, "bold")
    })
  })

  describe("comprehensive integration", () => {
    test("parses all supported patterns in a single message", () => {
      const input = `Hello **bold** and *italic* text.

Check \`inline code\` and [click here](https://example.com).

\`\`\`js
const x = 1;
console.log(x);
\`\`\`

Done!`

      const result = parseMarkdown(input)

      // Verify clean text output
      expect(result.text).toBe(`Hello bold and italic text.

Check inline code and click here.

const x = 1;
console.log(x);

Done!`)

      // Should have 5 entities
      expect(result.entities).toHaveLength(5)

      // 1. Bold: "bold" at position 6
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(6),
        length: BigInt(4),
        type: MessageEntity_Type.BOLD,
      })

      // 2. Italic: "italic" at position 15
      expect(result.entities[1]).toMatchObject({
        offset: BigInt(15),
        length: BigInt(6),
        type: MessageEntity_Type.ITALIC,
      })

      // 3. Inline code: "inline code"
      expect(result.entities[2]).toMatchObject({
        length: BigInt(11),
        type: MessageEntity_Type.CODE,
      })
      const codeStart = Number(result.entities[2]!.offset)
      expect(result.text.slice(codeStart, codeStart + 11)).toBe("inline code")

      // 4. Link: "click here" with url
      expect(result.entities[3]).toMatchObject({
        length: BigInt(10),
        type: MessageEntity_Type.TEXT_URL,
      })
      expect(result.entities[3]!.entity).toEqual({
        oneofKind: "textUrl",
        textUrl: { url: "https://example.com" },
      })
      const linkStart = Number(result.entities[3]!.offset)
      expect(result.text.slice(linkStart, linkStart + 10)).toBe("click here")

      // 5. Code block: with js language
      expect(result.entities[4]).toMatchObject({
        type: MessageEntity_Type.PRE,
      })
      expect(result.entities[4]!.entity).toEqual({
        oneofKind: "pre",
        pre: { language: "js" },
      })

      // Verify code block content is correct
      const codeBlockStart = Number(result.entities[4]!.offset)
      const codeBlockLength = Number(result.entities[4]!.length)
      const codeBlockContent = result.text.slice(codeBlockStart, codeBlockStart + codeBlockLength)
      expect(codeBlockContent).toBe("const x = 1;\nconsole.log(x);")
    })
  })

  describe("links edge cases", () => {
    test("link with special characters in URL", () => {
      const result = parseMarkdown("[text](https://a.com/path?q=1&x=2)")
      expect(result.text).toBe("text")
      expect(result.entities[0]!.entity).toEqual({
        oneofKind: "textUrl",
        textUrl: { url: "https://a.com/path?q=1&x=2" },
      })
    })

    test("link with spaces in text", () => {
      const result = parseMarkdown("[click here](https://example.com)")
      expect(result.text).toBe("click here")
      expect(result.entities[0]).toMatchObject({
        offset: BigInt(0),
        length: BigInt(10),
      })
    })

    test("multiple links", () => {
      const result = parseMarkdown("[one](url1) and [two](url2)")
      expect(result.text).toBe("one and two")
      expect(result.entities).toHaveLength(2)
    })
  })
})

describe("processMessageText", () => {
  test("parses markdown and returns entities", () => {
    const result = processMessageText({
      text: "Hello **bold** world",
      entities: undefined,
    })

    expect(result.text).toBe("Hello bold world")
    expect(result.entities?.entities).toHaveLength(1)
    expect(result.entities?.entities[0]).toMatchObject({
      offset: BigInt(6),
      length: BigInt(4),
      type: MessageEntity_Type.BOLD,
    })
  })

  test("parses link and returns text_url entity", () => {
    const result = processMessageText({
      text: "Check [this link](https://example.com) out",
      entities: undefined,
    })

    expect(result.text).toBe("Check this link out")
    expect(result.entities?.entities).toHaveLength(1)
    expect(result.entities?.entities[0]).toMatchObject({
      type: MessageEntity_Type.TEXT_URL,
    })
  })

  test("preserves multiline text", () => {
    const result = processMessageText({
      text: "Hello **bold**\nworld",
      entities: undefined,
    })

    expect(result.text).toBe("Hello bold\nworld")
  })

  test("returns undefined entities when no markdown", () => {
    const result = processMessageText({
      text: "Hello world",
      entities: undefined,
    })

    expect(result.text).toBe("Hello world")
    expect(result.entities).toBeUndefined()
  })

  test("preserves text with client entities if no markdown", () => {
    const result = processMessageText({
      text: "Hello world",
      entities: {
        entities: [
          {
            offset: BigInt(6),
            length: BigInt(5),
            type: MessageEntity_Type.BOLD,
            entity: { oneofKind: undefined },
          },
        ],
      },
    })

    expect(result.text).toBe("Hello world")
    expect(result.entities?.entities).toHaveLength(1)
  })

  test("discards client entities when markdown is parsed", () => {
    // Client sent entities for original text, but markdown changes offsets
    const result = processMessageText({
      text: "Hello **bold** world",
      entities: {
        entities: [
          {
            offset: BigInt(0),
            length: BigInt(5),
            type: MessageEntity_Type.ITALIC,
            entity: { oneofKind: undefined },
          },
        ],
      },
    })

    expect(result.text).toBe("Hello bold world")
    // Only the parsed bold entity, not the client's italic
    expect(result.entities?.entities).toHaveLength(1)
    expect(result.entities?.entities[0]!.type).toBe(MessageEntity_Type.BOLD)
  })

  test("preserves normal URLs", () => {
    const result = processMessageText({
      text: "Hello https://example.com world",
      entities: undefined,
    })

    expect(result.text).toBe("Hello https://example.com world")
    expect(result.entities).toBeUndefined()
  })

  test("keeps list bullets", () => {
    const result = processMessageText({
      text: "- hello\n- wow",
      entities: undefined,
    })

    expect(result.text).toBe("- hello\n- wow")
    expect(result.entities).toBeUndefined()
  })
})
