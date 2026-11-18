import { describe, expect, it } from "vitest"
import type { EntityType } from "@inline/core-protocol"
import { buildTextDocument } from "./build"
import type { BlockNode, EntityInput, InlineNode, ParagraphNode, TextDocument } from "./types"

const e = (type: EntityType, offset: number, length: number, extra: Partial<EntityInput> = {}): EntityInput =>
  ({ type, offset, length, ...extra }) as EntityInput

/** Text offsets of `needle` in `text`, as an entity range. */
const at = (text: string, needle: string, from = 0): [number, number] => {
  const offset = text.indexOf(needle, from)
  if (offset < 0) throw new Error(`"${needle}" not in "${text}"`)
  return [offset, needle.length]
}

const paragraphs = (doc: TextDocument): ParagraphNode[] =>
  doc.blocks.filter((b): b is ParagraphNode => b.kind === "paragraph")

const only = (doc: TextDocument): readonly InlineNode[] => {
  expect(doc.blocks).toHaveLength(1)
  const block = doc.blocks[0] as BlockNode
  expect(block.kind).toBe("paragraph")
  return (block as ParagraphNode).children
}

/** A compact rendering of a document for assertions: `[bold:Hi] there`. */
const sketch = (doc: TextDocument): string => doc.blocks.map(sketchBlock).join(" | ")
const sketchBlock = (block: BlockNode): string => {
  switch (block.kind) {
    case "paragraph":
      return block.children.map(sketchInline).join("")
    case "codeBlock":
      return `<pre${block.language ? `:${block.language}` : ""}>${block.text}</pre>`
    case "quote":
      return `<quote>${block.children.map(sketchBlock).join(" / ")}</quote>`
    case "mathBlock":
      return `<math>${block.source}</math>`
  }
}
const sketchInline = (node: InlineNode): string => {
  switch (node.kind) {
    case "text":
      return node.marks.length ? `[${node.marks.join("+")}:${node.text}]` : node.text
    case "math":
      return `{math:${node.source}}`
    case "link":
      return `{${node.link.kind}:${node.children.map(sketchInline).join("")}}`
    case "mention":
      return `{@${node.target.kind}:${node.children.map(sketchInline).join("")}}`
    case "threadRef":
      return `{#${node.target.kind}:${node.children.map(sketchInline).join("")}}`
    case "botCommand":
      return `{/${node.children.map(sketchInline).join("")}}`
  }
}

/** Every text run's offsets must point at its own text. */
const expectConsistent = (doc: TextDocument): void => {
  const visit = (node: InlineNode | BlockNode): void => {
    if (node.kind === "text") expect(doc.text.slice(node.start, node.end)).toBe(node.text)
    if (node.kind === "codeBlock") expect(doc.text.slice(node.start, node.end)).toBe(node.text)
    if (node.kind === "math" || node.kind === "mathBlock") expect(doc.text.slice(node.start, node.end)).toBe(node.source)
    expect(node.start).toBeLessThanOrEqual(node.end)
    if ("children" in node) for (const child of node.children) visit(child)
  }
  for (const block of doc.blocks) visit(block)
}

describe("plain text", () => {
  it("is one paragraph with one run", () => {
    const doc = buildTextDocument("Hello")
    expect(doc).toEqual({
      kind: "document",
      text: "Hello",
      dir: "ltr",
      blocks: [
        {
          kind: "paragraph",
          key: "p0",
          start: 0,
          end: 5,
          blankLinesBefore: 0,
          dir: "ltr",
          children: [{ kind: "text", key: "t0", start: 0, end: 5, text: "Hello", marks: [] }],
        },
      ],
    })
  })

  it("is empty for empty or non-string text", () => {
    expect(buildTextDocument("").blocks).toEqual([])
    expect(buildTextDocument(undefined).blocks).toEqual([])
    expect(buildTextDocument(42).blocks).toEqual([])
    expect(buildTextDocument(null, [e("bold", 0, 1)]).blocks).toEqual([])
    expect(buildTextDocument("\n\n  \n").blocks).toEqual([])
  })

  it("keeps single line breaks inside a paragraph and splits at blank lines", () => {
    const doc = buildTextDocument("one\ntwo\n\nthree\n\n\n\nfour\n")
    expect(paragraphs(doc).map((p) => [p.key, doc.text.slice(p.start, p.end), p.blankLinesBefore])).toEqual([
      ["p0", "one\ntwo", 0],
      ["p9", "three", 1],
      ["p18", "four", 3],
    ])
  })

  it("treats whitespace-only lines as blank and CR LF as one break", () => {
    const doc = buildTextDocument("a\r\n  \r\nb\r\nc")
    expect(paragraphs(doc).map((p) => doc.text.slice(p.start, p.end))).toEqual(["a", "b\r\nc"])
    expect(paragraphs(doc)[1]?.blankLinesBefore).toBe(1)
  })
})

describe("every entity type", () => {
  it("renders the marks", () => {
    const text = "b i u s h c"
    const doc = buildTextDocument(text, [
      e("bold", 0, 1),
      e("italic", 2, 1),
      e("underline", 4, 1),
      e("strikethrough", 6, 1),
      e("highlight", 8, 1),
      e("code", 10, 1),
    ])
    expect(sketch(doc)).toBe("[bold:b] [italic:i] [underline:u] [strikethrough:s] [highlight:h] [code:c]")
  })

  it("renders links of every source", () => {
    const text = "see example.com or docs or ada@example.com or +15551234567 or 555-123-4567"
    const doc = buildTextDocument(text, [
      e("url", ...at(text, "example.com")),
      e("textUrl", ...at(text, "docs"), { url: "https://docs.example.com/x" }),
      e("email", ...at(text, "ada@example.com")),
      e("phoneNumber", ...at(text, "+15551234567")),
      e("url", ...at(text, "555-123-4567")),
    ])
    const links = only(doc).filter((n) => n.kind === "link")
    expect(links.map((l) => (l.kind === "link" ? [l.source, l.link.kind, l.link.href] : []))).toEqual([
      ["url", "web", "https://example.com/"],
      ["textUrl", "web", "https://docs.example.com/x"],
      ["email", "mail", "mailto:ada@example.com"],
      ["phoneNumber", "phone", "tel:+15551234567"],
      ["url", "phone", "tel:5551234567"],
    ])
  })

  it("can turn phone links off", () => {
    const text = "+15551234567 and 555-123-4567"
    const doc = buildTextDocument(text, [e("phoneNumber", 0, 12), e("url", 17, 12)], { phoneNumbers: false })
    expect(sketch(doc)).toBe(text)
  })

  it("renders mentions of users, usernames and groups", () => {
    const text = "@Ada @ada_l @everyone"
    const doc = buildTextDocument(text, [
      e("mention", 0, 4, { userId: "7" as never }),
      e("usernameMention", 5, 6),
      e("groupMention", 12, 9, { groupId: "3" }),
    ])
    const nodes = only(doc)
    expect(nodes.filter((n) => n.kind === "mention").map((n) => (n.kind === "mention" ? n.target : null))).toEqual([
      { kind: "user", userId: "7" },
      { kind: "username", username: "ada_l" },
      { kind: "group", groupId: "3" },
    ])
  })

  it("carries a mention's agent ID when present", () => {
    const doc = buildTextDocument("@Bot", [e("mention", 0, 4, { userId: "7" as never, agentId: "9" })])
    expect(only(doc)[0]).toMatchObject({ kind: "mention", target: { kind: "user", userId: "7", agentId: "9" } })
  })

  it("renders thread references by chat and by title", () => {
    const text = "#launch and #ideas"
    const doc = buildTextDocument(text, [
      e("thread", 0, 7, { chatId: "42" as never }),
      e("threadTitle", 12, 6, { spaceId: "0" as never, title: " Ideas " }),
    ])
    const refs = only(doc).filter((n) => n.kind === "threadRef")
    expect(refs.map((r) => (r.kind === "threadRef" ? r.target : null))).toEqual([
      { kind: "chat", chatId: "42" },
      { kind: "title", spaceId: "0", title: "Ideas" },
    ])
  })

  it("renders bot commands with and without a bot", () => {
    const text = "/help /start"
    const doc = buildTextDocument(text, [e("botCommand", 0, 5, { botUserId: "5" as never }), e("botCommand", 6, 6)])
    const commands = only(doc).filter((n) => n.kind === "botCommand")
    expect(commands).toMatchObject([
      { command: "/help", botUserId: "5" },
      { command: "/start" },
    ])
    expect(commands[1]).not.toHaveProperty("botUserId")
  })

  it("renders code blocks with a sanitized language", () => {
    const text = "before\nconst x = 1\nafter"
    const doc = buildTextDocument(text, [e("pre", ...at(text, "const x = 1"), { language: "ts" })])
    expect(sketch(doc)).toBe("before | <pre:ts>const x = 1</pre> | after")
    const bad = buildTextDocument(text, [e("pre", ...at(text, "const x = 1"), { language: '"><img src=x>' })])
    expect(bad.blocks[1]).toMatchObject({ kind: "codeBlock", language: undefined })
  })

  it("renders a quote that owns whole lines, splitting its paragraphs at blank lines", () => {
    const text = "intro\nquoted one\nquoted two\n\nquoted three\noutro"
    const [offset] = at(text, "quoted one")
    const end = text.indexOf("\noutro")
    const doc = buildTextDocument(text, [e("blockquote", offset, end - offset)])
    expect(sketch(doc)).toBe("intro | <quote>quoted one\nquoted two / quoted three</quote> | outro")
  })

  it("renders math inline and as a block", () => {
    // The composer removes the `$` and `$$` markers; the entity covers the TeX source.
    const text = "where x^2 holds\n  \\sum_i i\nend"
    const inline = at(text, "x^2")
    const display = at(text, "\\sum_i i")
    const doc = buildTextDocument(text, [e("math", ...inline), e("math", ...display, { display: true })])
    expect(sketch(doc)).toBe("where {math:x^2} holds | <math>\\sum_i i</math> | end")
  })

  it("keeps display math inline when it shares its line", () => {
    const text = "so $$x$$ then"
    const doc = buildTextDocument(text, [e("math", ...at(text, "x"), { display: true })])
    expect(sketch(doc)).toBe("so $${math:x}$$ then")
  })
})

describe("textUrl targets inside the app (Mac parity)", () => {
  it("turns inline://user links into mentions", () => {
    const doc = buildTextDocument("Ada and Bo", [
      e("textUrl", 0, 3, { url: "inline://user/12" }),
      e("textUrl", 8, 2, { url: "inline://user?id=13&agent_id=4" }),
    ])
    expect(only(doc).filter((n) => n.kind === "mention")).toMatchObject([
      { target: { kind: "user", userId: "12" } },
      { target: { kind: "user", userId: "13", agentId: "4" } },
    ])
  })

  it("turns inline://chat and inline://thread links into thread references", () => {
    const doc = buildTextDocument("a b c", [
      e("textUrl", 0, 1, { url: "inline://chat/5" }),
      e("textUrl", 2, 1, { url: "in://thread?chat_id=6" }),
      e("textUrl", 4, 1, { url: "inline://thread?space_id=2&title=Plans" }),
    ])
    expect(only(doc).filter((n) => n.kind === "threadRef")).toMatchObject([
      { target: { kind: "chat", chatId: "5" } },
      { target: { kind: "chat", chatId: "6" } },
      { target: { kind: "title", spaceId: "2", title: "Plans" } },
    ])
  })

  it("keeps message links and other app links as app links", () => {
    const doc = buildTextDocument("a b c", [
      e("textUrl", 0, 1, { url: "inline://chat/5/message/9" }),
      e("textUrl", 2, 1, { url: "inline://chat/5?message_id=9" }),
      e("textUrl", 4, 1, { url: "https://inline.chat/c/5" }),
    ])
    expect(only(doc).filter((n) => n.kind === "link")).toMatchObject([
      { link: { kind: "app", form: "deepLink" } },
      { link: { kind: "app", form: "deepLink" } },
      { link: { kind: "app", form: "public" } },
    ])
  })
})

describe("unsafe and invalid targets degrade to text", () => {
  it.each([
    ["javascript:alert(1)"],
    ["data:text/html,hi"],
    ["//evil.com"],
    ["https://user:pw@example.com"],
    [42],
    [undefined],
  ])("textUrl %s", (url) => {
    const doc = buildTextDocument("click me", [e("textUrl", 0, 5, { url: url as string }), e("bold", 0, 5)])
    expect(sketch(doc)).toBe("[bold:click] me")
  })

  it("drops entities whose required fields are missing or invalid", () => {
    const text = "a b c d e f"
    const doc = buildTextDocument(text, [
      e("mention", 0, 1),
      e("mention", 2, 1, { userId: "0" as never }),
      e("mention", 4, 1, { userId: "-3" as never }),
      e("thread", 6, 1, { chatId: "x" as never }),
      e("threadTitle", 8, 1, { spaceId: "1" as never, title: "  " }),
      e("usernameMention", 10, 1, {}),
    ])
    // "f" is a valid username; the rest stay text.
    expect(sketch(doc)).toBe("a b c d e {@username:f}")
  })

  it("does not link a URL entity whose text is not a link", () => {
    const text = "javascript:alert(1) and notalink"
    const doc = buildTextDocument(text, [e("url", 0, 19), e("url", ...at(text, "notalink"))])
    expect(sketch(doc)).toBe(text)
  })
})

describe("overlap and nesting", () => {
  it("nests overlapping marks into runs", () => {
    const text = "abcdef"
    const doc = buildTextDocument(text, [e("bold", 0, 4), e("italic", 2, 4)])
    expect(sketch(doc)).toBe("[bold:ab][bold+italic:cd][italic:ef]")
  })

  it("applies marks inside and across containers", () => {
    const text = "go to example.com now"
    const doc = buildTextDocument(text, [e("url", ...at(text, "example.com")), e("bold", 3, 8)])
    expect(sketch(doc)).toBe("go [bold:to ]{web:[bold:examp]le.com} now")
  })

  it("merges adjacent runs with the same marks", () => {
    const doc = buildTextDocument("abcdef", [e("bold", 0, 3), e("bold", 3, 3)])
    expect(only(doc)).toHaveLength(1)
    expect(sketch(doc)).toBe("[bold:abcdef]")
  })

  it("treats duplicate marks as one", () => {
    const doc = buildTextDocument("abc", [e("bold", 0, 3), e("bold", 0, 3), e("bold", 1, 1)])
    expect(sketch(doc)).toBe("[bold:abc]")
  })

  it("never overlaps containers: the earliest, then longest, then first wins", () => {
    const text = "@Ada example.com"
    const doc = buildTextDocument(text, [
      e("url", 3, 13), // overlaps the mention, starts later: dropped
      e("mention", 0, 4, { userId: "1" as never }),
    ])
    expect(sketch(doc)).toBe("{@user:@Ada} example.com")

    const same = buildTextDocument("abc.com", [e("url", 0, 7), e("textUrl", 0, 7, { url: "https://x.com" })])
    expect(only(same)[0]).toMatchObject({ kind: "link", source: "url" })

    const longer = buildTextDocument("abc.com", [e("mention", 0, 3, { userId: "1" as never }), e("url", 0, 7)])
    expect(sketch(longer)).toBe("{web:abc.com}")
  })

  it("does not nest containers", () => {
    const text = "see @Ada here"
    const doc = buildTextDocument(text, [
      e("textUrl", 0, text.length, { url: "https://example.com" }),
      e("mention", 4, 4, { userId: "1" as never }),
    ])
    expect(sketch(doc)).toBe("{web:see @Ada here}")
  })

  it("accepts entities in any order", () => {
    const text = "one two three"
    const entities = [e("italic", 8, 5), e("bold", 0, 3), e("url", ...at(text, "two")), e("underline", 2, 8)]
    const forward = buildTextDocument(text, entities)
    const backward = buildTextDocument(text, [...entities].reverse())
    // `two` is not a domain, so the url entity renders as text.
    expect(sketch(forward)).toBe(sketch(backward))
    expect(sketch(forward)).toBe("[bold:on][bold+underline:e][underline: two ][italic+underline:th][italic:ree]")
  })

  it("splits a container that spans a paragraph break into one per paragraph", () => {
    const text = "aa\n\nbb"
    const doc = buildTextDocument(text, [e("textUrl", 0, 6, { url: "https://example.com" })])
    expect(sketch(doc)).toBe("{web:aa} | {web:bb}")
    expect(paragraphs(doc).map((p) => p.children[0]?.key)).toEqual(["l0", "l4"])
  })

  it("ignores entities inside a code block and keeps the code literal", () => {
    const text = "```\n**x** @Ada\n```"
    const inner = at(text, "**x** @Ada")
    const doc = buildTextDocument(text, [
      e("pre", ...inner),
      e("bold", inner[0], 5),
      e("mention", inner[0] + 6, 4, { userId: "1" as never }),
    ])
    expect(doc.blocks.find((b) => b.kind === "codeBlock")).toMatchObject({ text: "**x** @Ada" })
  })

  it("keeps the first of overlapping code blocks", () => {
    const text = "abcdef"
    const doc = buildTextDocument(text, [e("pre", 2, 4), e("pre", 0, 4)])
    expect(sketch(doc)).toBe("<pre>abcd</pre> | ef")
  })

  it("splits a line around a code block", () => {
    const text = "run npm test now"
    const doc = buildTextDocument(text, [e("pre", ...at(text, "npm test"))])
    // Spaces next to the block stay with their paragraph.
    expect(sketch(doc)).toBe("run  | <pre>npm test</pre> |  now")
  })

  it("treats math inside code as code text", () => {
    const text = "x $y$ z"
    const doc = buildTextDocument(text, [e("code", 0, 7), e("math", 3, 1)])
    expect(sketch(doc)).toBe("[code:x $y$ z]")
  })

  it("lets inline math win over other containers and ignores marks inside it", () => {
    const text = "a+b"
    const doc = buildTextDocument(text, [e("url", 0, 3), e("math", 0, 3), e("bold", 0, 3)])
    expect(sketch(doc)).toBe("{math:a+b}")
  })
})

describe("quotes (Mac literal block rule)", () => {
  it("ignores a quote that does not own whole lines", () => {
    const text = "say hello there"
    const doc = buildTextDocument(text, [e("blockquote", ...at(text, "hello"))])
    expect(sketch(doc)).toBe(text)
  })

  it("ignores a quote that includes the trailing line break", () => {
    const text = "quoted\nnext"
    const doc = buildTextDocument(text, [e("blockquote", 0, 7)])
    expect(sketch(doc)).toBe("quoted\nnext")
  })

  it("ignores a quote that touches a code block", () => {
    const text = "line one\nline two"
    const doc = buildTextDocument(text, [e("blockquote", 0, text.length), e("pre", ...at(text, "two"))])
    expect(doc.blocks.some((b) => b.kind === "quote")).toBe(false)
  })

  it("keeps the earliest, then shortest, of overlapping quotes", () => {
    const text = "a\nb\nc"
    const doc = buildTextDocument(text, [e("blockquote", 0, 5), e("blockquote", 0, 3), e("blockquote", 2, 3)])
    expect(sketch(doc)).toBe("<quote>a\nb</quote> | c")
  })

  it("renders marks and mentions inside a quote", () => {
    const text = "hi @Ada"
    const doc = buildTextDocument(text, [e("blockquote", 0, 7), e("bold", 0, 2), e("mention", 3, 4, { userId: "1" as never })])
    expect(sketch(doc)).toBe("<quote>[bold:hi] {@user:@Ada}</quote>")
  })
})

describe("malformed ranges never throw and degrade to plain text", () => {
  const text = "hello world"
  it.each([
    ["negative offset", e("bold", -1, 3)],
    ["zero length", e("bold", 0, 0)],
    ["negative length", e("bold", 3, -2)],
    ["past the end", e("bold", 6, 6)],
    ["offset past the end", e("bold", 20, 1)],
    ["fractional", e("bold", 1.5, 2)],
    ["NaN", e("bold", Number.NaN, 2)],
    ["Infinity", e("bold", 0, Number.POSITIVE_INFINITY)],
    ["huge", e("bold", Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER)],
    ["string offset", { type: "bold", offset: "0", length: 3 }],
    ["bigint offset", { type: "bold", offset: 0n, length: 3n }],
    ["unknown type", { type: "blink", offset: 0, length: 3 }],
    ["unspecified type", { type: undefined, offset: 0, length: 3 }],
    ["null", null],
    ["a string", "bold"],
    ["an array", [0, 3]],
  ])("%s", (_name, entity) => {
    const doc = buildTextDocument(text, [entity])
    expect(sketch(doc)).toBe(text)
  })

  it.each([[undefined], [null], ["entities"], [{ length: 1, 0: e("bold", 0, 1) }], [42]])("entities = %s", (entities) => {
    expect(sketch(buildTextDocument(text, entities))).toBe(text)
  })

  it("keeps valid entities next to invalid ones", () => {
    const doc = buildTextDocument(text, [null, e("bold", -5, 2), e("bold", 0, 5), e("italic", 99, 1)])
    expect(sketch(doc)).toBe("[bold:hello] world")
  })

  it("survives a large random fuzz without throwing and stays consistent", () => {
    let seed = 1234567
    const random = (): number => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff
      return seed / 0x7fffffff
    }
    const alphabet = ["a", " ", "\n", "\u00e9", "e\u0301", "\u{1F469}\u200d\u{1F4BB}", "\u05e9", "\r\n", "\u{1F600}", "@", "."]
    const types: EntityType[] = ["bold", "italic", "code", "pre", "blockquote", "url", "textUrl", "mention", "math", "highlight"]
    for (let round = 0; round < 300; round += 1) {
      let fuzz = ""
      const parts = Math.floor(random() * 40)
      for (let i = 0; i < parts; i += 1) fuzz += alphabet[Math.floor(random() * alphabet.length)]
      const entities = Array.from({ length: Math.floor(random() * 8) }, () =>
        e(types[Math.floor(random() * types.length)] ?? "bold", Math.floor(random() * (fuzz.length + 4)) - 2, Math.floor(random() * 10) - 1, {
          url: "https://example.com",
          userId: "1" as never,
          display: random() > 0.5,
        }),
      )
      try {
        const doc = buildTextDocument(fuzz, entities)
        expectConsistent(doc)
      } catch (error) {
        throw new Error(`seed round ${round}: ${JSON.stringify({ fuzz, entities })}: ${String(error)}`)
      }
    }
  })
})

describe("UTF-16 edge cases", () => {
  it("measures offsets in UTF-16 code units around emoji", () => {
    const text = "\u{1F600} bold"
    // The emoji is two code units.
    const doc = buildTextDocument(text, [e("bold", 3, 4)])
    expect(sketch(doc)).toBe("\u{1F600} [bold:bold]")
  })

  it("drops an entity that starts or ends inside a surrogate pair (Mac parity)", () => {
    const text = "a\u{1F600}b"
    expect(sketch(buildTextDocument(text, [e("bold", 2, 2)]))).toBe(text)
    expect(sketch(buildTextDocument(text, [e("bold", 0, 2)]))).toBe(text)
    expect(sketch(buildTextDocument(text, [e("bold", 1, 2)]))).toBe("a[bold:\u{1F600}]b")
  })

  it("widens an entity that cuts a combining sequence to the whole cluster", () => {
    const text = "cafe\u0301 ok"
    // Bold on "e" alone would separate it from its accent.
    const doc = buildTextDocument(text, [e("bold", 3, 1)])
    expect(sketch(doc)).toBe("caf[bold:e\u0301] ok")
  })

  it("widens an entity that cuts a ZWJ emoji sequence", () => {
    const family = "\u{1F468}\u200d\u{1F469}\u200d\u{1F467}"
    const text = `x${family}y`
    // Ends after the first person, inside the sequence.
    const doc = buildTextDocument(text, [e("bold", 0, 3)])
    expect(sketch(doc)).toBe(`[bold:x${family}]y`)
  })

  it("widens an entity that cuts a flag or a skin tone", () => {
    const flag = "\u{1F1E9}\u{1F1EA}"
    const thumbs = "\u{1F44D}\u{1F3FD}"
    const text = `${flag} ${thumbs}`
    const doc = buildTextDocument(text, [e("italic", 0, 2), e("bold", 5, 2)])
    expect(sketch(doc)).toBe(`[italic:${flag}] [bold:${thumbs}]`)
  })

  it("does not split CR LF", () => {
    const doc = buildTextDocument("a\r\nb", [e("bold", 0, 2)])
    expect(sketch(doc)).toBe("[bold:a\r\n]b")
  })

  it("renders right-to-left text mixed with left-to-right", () => {
    const text = "\u0633\u0644\u0627\u0645 Inline \u062f\u0646\u06cc\u0627"
    const doc = buildTextDocument(text, [e("bold", ...at(text, "Inline"))])
    expect(sketch(doc)).toBe("\u0633\u0644\u0627\u0645 [bold:Inline] \u062f\u0646\u06cc\u0627")
    expect(doc.dir).toBe("rtl")
    expectConsistent(doc)
  })

  it("keeps Arabic combining marks with their letter", () => {
    const text = "\u0628\u0650\u0633\u0652\u0645"
    const doc = buildTextDocument(text, [e("bold", 0, 1)])
    expect(sketch(doc)).toBe("[bold:\u0628\u0650]\u0633\u0652\u0645")
  })
})

describe("direction", () => {
  it("decides the message and each paragraph by word majority", () => {
    const persian = "\u0627\u06cc\u0646 \u06cc\u06a9 \u067e\u06cc\u0627\u0645 \u0641\u0627\u0631\u0633\u06cc \u0627\u0633\u062a"
    const english = "this is a long English paragraph"
    const doc = buildTextDocument(`${persian}\n\n${english}\n\n123`)
    expect(paragraphs(doc).map((p) => p.dir)).toEqual(["rtl", "ltr", undefined])
    expect(doc.dir).toBe("ltr")
  })

  it("lets a short paragraph follow the message", () => {
    const persian = "\u0627\u06cc\u0646 \u06cc\u06a9 \u067e\u06cc\u0627\u0645 \u0641\u0627\u0631\u0633\u06cc \u0627\u0633\u062a \u0648 \u0628\u0644\u0646\u062f"
    const doc = buildTextDocument(`Sources:\n\n${persian}`)
    expect(doc.dir).toBe("rtl")
    expect(paragraphs(doc).map((p) => p.dir)).toEqual(["rtl", "rtl"])
  })
})
