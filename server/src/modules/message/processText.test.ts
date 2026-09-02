import { describe, test, expect } from "bun:test"
import { processMessageText } from "./processText"
import { parseMarkdown, parseMarkdownWithSourceMap } from "./parseMarkdown"
import { MessageEntity_Type } from "@inline-chat/protocol/core"

describe("parseMarkdown", () => {
  test("source map preserves UTF-16 boundaries through nested markup", () => {
    const input = "😀 **bold `code`** end"
    const parsed = parseMarkdownWithSourceMap(input)
    const sourceStart = input.indexOf("bold")
    const sourceEnd = input.indexOf("** end")
    const outputStart = parsed.sourceToOutput[sourceStart]!
    const outputEnd = parsed.sourceToOutput[sourceEnd]!

    expect(parsed.text.slice(outputStart, outputEnd)).toBe("bold code")
    expect(parsed.text).toBe(parseMarkdown(input).text)
    expect(parsed.entities).toEqual(parseMarkdown(input).entities)
  })

  test("source map follows trimmed fenced-code compatibility semantics", () => {
    const input = "before\n```swift\n  let x = 1  \n```\nafter"
    const parsed = parseMarkdownWithSourceMap(input)
    const codeStart = input.indexOf("let x")
    const codeEnd = codeStart + "let x = 1".length

    expect(parsed.text.slice(parsed.sourceToOutput[codeStart], parsed.sourceToOutput[codeEnd])).toBe("let x = 1")
    expect(parsed.text).toBe(parseMarkdown(input).text)
    expect(parsed.entities).toEqual(parseMarkdown(input).entities)
  })

  test("decodes structural escapes without creating entities", () => {
    const input = String.raw`\# heading \- item \*literal\* \[link\]\(target\) \\ path`
    const parsed = parseMarkdownWithSourceMap(input)

    expect(parsed.text).toBe("# heading - item *literal* [link](target) \\ path")
    expect(parsed.entities).toEqual([])
    expect(parsed.sourceToOutput).toHaveLength(input.length + 1)
    expect(parsed.sourceToOutput[input.length]).toBe(parsed.text.length)
  })

  test("supports adaptive backtick and tilde fences with extended languages", () => {
    const input = [
      "````c++",
      "const value = `inline`;",
      "```",
      "````",
      "after",
      "~~~objective-c",
      "id value = nil;",
      "~~~",
    ].join("\r\n")
    const parsed = parseMarkdown(input)

    expect(parsed.text).toBe("const value = `inline`;\r\n```\r\nafter\r\nid value = nil;")
    expect(parsed.entities.map((entity) => entity.type)).toEqual([
      MessageEntity_Type.PRE,
      MessageEntity_Type.PRE,
    ])
    expect(parsed.entities.map((entity) => entity.entity.oneofKind === "pre" ? entity.entity.pre.language : "")).toEqual([
      "c++",
      "objective-c",
    ])
  })

  test("supports inline code delimiters longer than their contents", () => {
    const parsed = parseMarkdown("before ``value with ` tick`` after")

    expect(parsed.text).toBe("before value with ` tick after")
    expect(parsed.entities).toHaveLength(1)
    expect(parsed.entities[0]).toMatchObject({
      offset: 7n,
      length: 17n,
      type: MessageEntity_Type.CODE,
    })
  })

  test("keeps an open adaptive fence as code while its closing delimiter streams", () => {
    for (let length = 1; length < 3; length++) {
      const partialOpening = "`".repeat(length)
      expect(parseMarkdown(partialOpening)).toEqual({ text: partialOpening, entities: [] })
    }

    const complete = "````swift\nlet value = 1\n````"
    const closingStart = complete.lastIndexOf("````")
    for (let length = 1; length < 4; length++) {
      const prefix = complete.slice(0, closingStart + length)
      const parsed = parseMarkdown(prefix)
      expect(parsed.entities).toHaveLength(1)
      expect(parsed.entities[0]?.type).toBe(MessageEntity_Type.PRE)
      expect(parsed.text).toBe(`let value = 1\n${"`".repeat(length)}`)
    }
    expect(parseMarkdown(complete).entities[0]?.type).toBe(MessageEntity_Type.PRE)
  })

  test("keeps completed and trailing open code fences as separate entities", () => {
    const input = [
      "```ts",
      "const first = true",
      "```",
      "```swift",
      "let second = `value`",
      "[not a link](target)",
    ].join("\n")
    const parsed = parseMarkdown(input)

    expect(parsed.text).toBe([
      "const first = true",
      "let second = `value`",
      "[not a link](target)",
    ].join("\n"))
    expect(parsed.entities.map((entity) => entity.type)).toEqual([
      MessageEntity_Type.PRE,
      MessageEntity_Type.PRE,
    ])
    expect(parsed.entities.map((entity) => entity.entity.oneofKind === "pre" ? entity.entity.pre.language : ""))
      .toEqual(["ts", "swift"])
  })

  test("keeps repeated terminal progress counters outside their completed fence", () => {
    const input = [
      "```",
      "first command",
      "```",
      "```",
      "repeated command",
      "``` (×3)",
      "```",
      "next command",
      "```",
    ].join("\n")
    const parsed = parseMarkdown(input)

    expect(parsed.text).toBe([
      "first command",
      "repeated command",
      "(×3)",
      "next command",
    ].join("\n"))
    expect(parsed.entities.map((entity) => entity.type)).toEqual([
      MessageEntity_Type.PRE,
      MessageEntity_Type.PRE,
      MessageEntity_Type.PRE,
    ])
    expect(parsed.entities.map((entity) => parsed.text.slice(
      Number(entity.offset),
      Number(entity.offset + entity.length),
    ))).toEqual(["first command", "repeated command", "next command"])
  })

  test("does not reinterpret repetition-like opening fence info", () => {
    const parsed = parseMarkdown([
      "``` (×3)",
      "literal body",
      "```",
    ].join("\n"))

    expect(parsed.text).toBe("literal body")
    expect(parsed.entities).toHaveLength(1)
    expect(parsed.entities[0]?.type).toBe(MessageEntity_Type.PRE)
  })

  test("leaves ambiguous trailing inline Markdown literal", () => {
    const input = "**complete**\n\nunfinished **bold and [link](https://example.com"
    const parsed = parseMarkdown(input)

    expect(parsed.text).toBe("complete\n\nunfinished **bold and [link](https://example.com")
    expect(parsed.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.BOLD])
  })

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

    test("code block preserves link syntax without nested parsing", () => {
      const result = parseMarkdown("```\n[not a link](https://example.com)\n```")
      expect(result.text).toBe("[not a link](https://example.com)")
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

    test("unclosed code block extends through the end of the snapshot", () => {
      const result = parseMarkdown("```js\ncode without closing")
      expect(result.text).toBe("code without closing")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        offset: 0n,
        length: 20n,
        type: MessageEntity_Type.PRE,
        entity: { oneofKind: "pre", pre: { language: "js" } },
      })
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

    test("inline code wrapped by bold still blocks markdown parsing inside code", () => {
      const result = parseMarkdown("**`[not a link](url)`**")
      expect(result.text).toBe("[not a link](url)")
      expect(result.entities).toHaveLength(2)

      const boldEntity = result.entities.find((entity) => entity.type === MessageEntity_Type.BOLD)
      const codeEntity = result.entities.find((entity) => entity.type === MessageEntity_Type.CODE)
      const linkEntity = result.entities.find((entity) => entity.type === MessageEntity_Type.TEXT_URL)

      expect(boldEntity).toMatchObject({
        offset: BigInt(0),
        length: BigInt(17),
        type: MessageEntity_Type.BOLD,
      })
      expect(codeEntity).toMatchObject({
        offset: BigInt(0),
        length: BigInt(17),
        type: MessageEntity_Type.CODE,
      })
      expect(linkEntity).toBeUndefined()
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

    test("bold wrapping a markdown link preserves both entities", () => {
      const result = parseMarkdown("**[click here](https://example.com)**")

      expect(result.text).toBe("click here")
      expect(result.entities).toHaveLength(2)

      const boldEntity = result.entities.find((entity) => entity.type === MessageEntity_Type.BOLD)
      const linkEntity = result.entities.find((entity) => entity.type === MessageEntity_Type.TEXT_URL)

      expect(boldEntity).toMatchObject({
        offset: BigInt(0),
        length: BigInt(10),
        type: MessageEntity_Type.BOLD,
      })
      expect(linkEntity).toMatchObject({
        offset: BigInt(0),
        length: BigInt(10),
        type: MessageEntity_Type.TEXT_URL,
      })
      expect(linkEntity?.entity).toEqual({
        oneofKind: "textUrl",
        textUrl: { url: "https://example.com" },
      })
    })

    test("markdown link text can contain bold formatting", () => {
      const result = parseMarkdown("[**click here**](https://example.com)")

      expect(result.text).toBe("click here")
      expect(result.entities).toHaveLength(2)

      const boldEntity = result.entities.find((entity) => entity.type === MessageEntity_Type.BOLD)
      const linkEntity = result.entities.find((entity) => entity.type === MessageEntity_Type.TEXT_URL)

      expect(boldEntity).toMatchObject({
        offset: BigInt(0),
        length: BigInt(10),
        type: MessageEntity_Type.BOLD,
      })
      expect(linkEntity).toMatchObject({
        offset: BigInt(0),
        length: BigInt(10),
        type: MessageEntity_Type.TEXT_URL,
      })
      expect(linkEntity?.entity).toEqual({
        oneofKind: "textUrl",
        textUrl: { url: "https://example.com" },
      })
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

    test("an incomplete disclosure opener stays literal until its summary is complete", () => {
      for (const input of [
        "<details>",
        "<details>\n<summary",
        "<details open>\n<summary kind=\"progress\">Working",
      ]) {
        expect(parseMarkdown(input)).toEqual({ text: input, entities: [] })
      }
    })

    test("a complete disclosure summary may stream without the closing details tag", () => {
      const input = "<details open>\n<summary>Working</summary>\n**step one**"
      const result = parseMarkdown(input)

      expect(result.text).toBe("\n▸ Working\n\tstep one")
      expect(result.entities).toEqual([
        expect.objectContaining({
          offset: 12n,
          length: 8n,
          type: MessageEntity_Type.BOLD,
        }),
      ])
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

    test("link URL supports nested parentheses", () => {
      const result = parseMarkdown("[wiki](https://en.wikipedia.org/wiki/Function_(mathematics))")
      expect(result.text).toBe("wiki")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]!.type).toBe(MessageEntity_Type.TEXT_URL)
      expect(result.entities[0]!.entity).toEqual({
        oneofKind: "textUrl",
        textUrl: { url: "https://en.wikipedia.org/wiki/Function_(mathematics)" },
      })
    })

    test("link URL supports multiple nested parentheses", () => {
      const result = parseMarkdown("[label](https://example.com/a(b(c)d)e)")
      expect(result.text).toBe("label")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]!.entity).toEqual({
        oneofKind: "textUrl",
        textUrl: { url: "https://example.com/a(b(c)d)e" },
      })
    })

    test("link destinations decode escaped punctuation without ending early", () => {
      const cases: [string, string][] = [
        [String.raw`[x](https://e/a\)b)`, "https://e/a)b"],
        [String.raw`[x](https://e/a\(b)`, "https://e/a(b"],
        [String.raw`[x](https://e/a(b\)c)d)`, "https://e/a(b)c)d"],
        [String.raw`[x](https://e/a\\)`, "https://e/a\\"],
        [String.raw`[x](https://e/a\q)`, String.raw`https://e/a\q`],
      ]
      for (const [input, url] of cases) {
        const parsed = parseMarkdownWithSourceMap(`😀 ${input} **end**`)
        expect(parsed.text).toBe("😀 x end")
        expect(parsed.entities[0]).toMatchObject({
          offset: 3n,
          length: 1n,
          type: MessageEntity_Type.TEXT_URL,
          entity: { oneofKind: "textUrl", textUrl: { url } },
        })
        expect(parsed.sourceToOutput.at(-1)).toBe(parsed.text.length)
      }
    })

    test("a streamed escaped close cannot terminate a link before its real delimiter", () => {
      const input = String.raw`before [x](https://e/a\)b)`
      for (let end = input.indexOf("\\"); end < input.length; end++) {
        const parsed = parseMarkdown(input.slice(0, end))
        expect(parsed.entities.some((entity) => entity.type === MessageEntity_Type.TEXT_URL)).toBe(false)
        expect(parsed.text).toContain("[x](https://e/a")
      }
      expect(parseMarkdown(input).text).toBe("before x")
    })

    test("unbalanced markdown link parentheses stay unchanged", () => {
      const result = parseMarkdown("[label](https://example.com/a(b)")
      expect(result.text).toBe("[label](https://example.com/a(b)")
      expect(result.entities).toHaveLength(0)
    })
  })

  describe("unicode and boundary edge cases", () => {
    test("handles cjk text with markdown entities", () => {
      const result = parseMarkdown("你好 **世界** [链接](https://example.com)")
      expect(result.text).toBe("你好 世界 链接")
      expect(result.entities).toHaveLength(2)
      expect(result.entities[0]).toMatchObject({
        type: MessageEntity_Type.BOLD,
        offset: BigInt(3),
        length: BigInt(2),
      })
      expect(result.entities[1]).toMatchObject({
        type: MessageEntity_Type.TEXT_URL,
        offset: BigInt(6),
        length: BigInt(2),
      })
    })

    test("handles emoji offsets correctly", () => {
      const result = parseMarkdown("emoji 😀 **bold** end")
      expect(result.text).toBe("emoji 😀 bold end")
      expect(result.entities).toHaveLength(1)
      expect(result.entities[0]).toMatchObject({
        type: MessageEntity_Type.BOLD,
        offset: BigInt(9),
        length: BigInt(4),
      })
    })

    test("underscore emphasis does not parse inside snake_case words", () => {
      const result = parseMarkdown("foo_bar_baz")
      expect(result.text).toBe("foo_bar_baz")
      expect(result.entities).toHaveLength(0)
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

  test("preserves unrelated client entities when markdown is parsed", () => {
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
    expect(result.entities?.entities).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: MessageEntity_Type.ITALIC, offset: 0n, length: 5n }),
      expect.objectContaining({ type: MessageEntity_Type.BOLD, offset: 6n, length: 4n }),
    ]))
    expect(result.entities?.entities).toHaveLength(2)
  })

  test("remaps explicit Agent mentions after Unicode, escapes, and nested markup", () => {
    const text = "😀 " + String.raw`\* **bold** [label](https://example.com) Maya`
    const entity = {
      type: MessageEntity_Type.MENTION,
      offset: BigInt(text.indexOf("Maya")),
      length: 4n,
      entity: { oneofKind: "mention" as const, mention: { userId: 7n, agentId: 9n } },
    }
    const parsed = parseMarkdownWithSourceMap(text)
    const result = processMessageText({ text, entities: { entities: [entity] }, parsedMarkdown: parsed })

    expect(result.text).toBe("😀 * bold label Maya")
    expect(result.entities?.entities).toContainEqual({
      ...entity,
      offset: BigInt(result.text.indexOf("Maya")),
    })
    expect(entity.offset).toBe(BigInt(text.indexOf("Maya")))
  })

  test("remaps a formatting span across nested Markdown content", () => {
    const text = "before **bold [link](https://example.com)** after"
    const result = processMessageText({
      text,
      entities: { entities: [{
        type: MessageEntity_Type.ITALIC,
        offset: 7n,
        length: BigInt(text.indexOf(" after") - 7),
        entity: { oneofKind: undefined },
      }] },
    })
    expect(result.text).toBe("before bold link after")
    expect(result.entities?.entities).toContainEqual({
      type: MessageEntity_Type.ITALIC,
      offset: 7n,
      length: 9n,
      entity: { oneofKind: undefined },
    })
  })

  test("discards removed, invalid, and split-surrogate source ranges", () => {
    const text = "😀 **bold** [link](hidden)"
    const ranges: [bigint, bigint][] = [
      [-1n, 1n], [0n, 0n], [0n, 100n], [2n ** 62n, 1n],
      [0n, 1n], [1n, 1n], [3n, 2n], [BigInt(text.indexOf("hidden")), 6n],
    ]
    const result = processMessageText({
      text,
      entities: { entities: ranges.map(([offset, length]) => ({
        type: MessageEntity_Type.MENTION,
        offset, length,
        entity: { oneofKind: "mention" as const, mention: { userId: 7n } },
      })) },
    })
    expect(result.entities?.entities.some((entity) => entity.type === MessageEntity_Type.MENTION)).toBe(false)
  })

  test("does not turn explicit mentions inside parsed code into interactive text", () => {
    for (const text of ["`Maya` **bold**", "```\nMaya\n```\n**bold**"]) {
      const result = processMessageText({
        text,
        entities: { entities: [{
          type: MessageEntity_Type.MENTION,
          offset: BigInt(text.indexOf("Maya")), length: 4n,
          entity: { oneofKind: "mention", mention: { userId: 7n } },
        }] },
      })
      expect(result.entities?.entities.some((entity) => entity.type === MessageEntity_Type.MENTION)).toBe(false)
      expect(result.text).toContain("Maya")
    }
  })

  test("checks large client entity sets against merged verbatim ranges", () => {
    const chunks: string[] = []
    const entities = []
    let sourceLength = 0
    for (let index = 0; index < 2_048; index++) {
      const prefix = index === 0 ? "" : " "
      const chunk = `${prefix}\`x\` y`
      const codeOffset = sourceLength + prefix.length + 1
      const textOffset = sourceLength + chunk.length - 1
      chunks.push(chunk)
      entities.push(
        { type: MessageEntity_Type.MENTION, offset: BigInt(codeOffset), length: 1n,
          entity: { oneofKind: "mention" as const, mention: { userId: 7n } } },
        { type: MessageEntity_Type.MENTION, offset: BigInt(textOffset), length: 1n,
          entity: { oneofKind: "mention" as const, mention: { userId: 8n } } },
      )
      sourceLength += chunk.length
    }

    const result = processMessageText({ text: chunks.join(""), entities: { entities } })
    const mentions = result.entities?.entities.filter((entity) => entity.type === MessageEntity_Type.MENTION) ?? []
    expect(mentions).toHaveLength(2_048)
    expect(mentions.every((entity) => entity.entity.oneofKind === "mention"
      && entity.entity.mention.userId === 8n)).toBe(true)
  })

  test("keeps parser precedence for duplicate or conflicting client entities", () => {
    const text = "**bold** [label](https://parsed.example)"
    const result = processMessageText({
      text,
      entities: { entities: [
        { type: MessageEntity_Type.BOLD, offset: 2n, length: 4n, entity: { oneofKind: undefined } },
        {
          type: MessageEntity_Type.TEXT_URL, offset: 10n, length: 5n,
          entity: { oneofKind: "textUrl", textUrl: { url: "https://client.example" } },
        },
      ] },
    })
    expect(result.entities?.entities).toEqual(parseMarkdown(text).entities)
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
