import { describe, expect, it } from "vitest"
import {
  buildInlineWidgetHtmlFromOpenClaw,
  buildInlineWidgetMarkdown,
  chunkInlineMarkdownWithWidgets,
  deriveInlineWidgetId,
  escapeInlineWidgetAttribute,
  extractOpenClawWidgetSource,
  findInlineWidgetSpans,
  INLINE_MESSAGE_MAX_UTF16_UNITS,
  InlineWidgetError,
  mapInlineTextOutsideWidgets,
  OPENCLAW_WIDGET_COMPAT_PRELUDE,
  splitInlineWidgetMessages,
  splitInlineWidgetStreamTail,
  takeInlineWidgetStreamText,
} from "./widgets.js"

const widget = (body: string, id = "w") => `<iframe title="T" id="${id}" height="200">\n${body}\n</iframe>`

/** Splits on blank lines and hard-cuts long paragraphs, like a Markdown chunker would. */
function naiveChunk(text: string, limit: number): string[] {
  const out: string[] = []
  for (const paragraph of text.split(/\n{2,}/)) {
    for (let index = 0; index < paragraph.length; index += limit) out.push(paragraph.slice(index, index + limit))
  }
  return out
}

describe("inline widget spans", () => {
  it("finds widget blocks outside code fences, mirroring the server", () => {
    const fenced = "```html\n<iframe title=\"x\">\n<p>x</p>\n</iframe>\n```"
    const text = `Intro\n\n${widget("<p>a</p>")}\n\n${fenced}\n\n${widget("<p>b</p>", "two")}`
    const spans = findInlineWidgetSpans(text)
    expect(spans).toHaveLength(2)
    expect(text.slice(spans[0]!.start, spans[0]!.end)).toBe(widget("<p>a</p>"))
    expect(text.slice(spans[1]!.start, spans[1]!.end)).toBe(widget("<p>b</p>", "two"))
  })

  it("requires the opener at a line start and marks an unclosed widget", () => {
    expect(findInlineWidgetSpans("see <iframe title=\"x\">")).toEqual([])
    const text = "Intro\n\n<iframe title=\"x\">\n<p>still going"
    expect(findInlineWidgetSpans(text)).toEqual([{ start: 7, end: text.length, closed: false }])
  })

  it("transforms only the Markdown around widgets", () => {
    const text = `a \`https://x.dev\`\n\n${widget("<script>const u = `https://x.dev`</script>")}\n\nb`
    const result = mapInlineTextOutsideWidgets(text, (segment) => segment.toUpperCase())
    expect(result).toContain("const u = `https://x.dev`")
    expect(result.startsWith("A `HTTPS://X.DEV`")).toBe(true)
    expect(result.endsWith("\n\nB")).toBe(true)
  })
})

describe("widget-aware chunking", () => {
  it("delegates text without widgets to the chunker unchanged", () => {
    expect(chunkInlineMarkdownWithWidgets("a\n\nb", 1, naiveChunk)).toEqual(["a", "b"])
  })

  it("never splits a widget that is larger than the chunk limit", () => {
    const html = Array.from({ length: 40 }, (_, index) => `<p>row ${index}</p>\n`).join("\n")
    const block = widget(html)
    const chunks = chunkInlineMarkdownWithWidgets(`Revenue grew 18%.\n\n${block}\n\nThat is all.`, 200, naiveChunk)
    expect(chunks).toEqual([`Revenue grew 18%.\n\n${block}`, "That is all."])
  })

  it("keeps a short message with its widget whole", () => {
    const text = `Intro\n\n${widget("<p>x</p>")}\n\nOutro`
    expect(chunkInlineMarkdownWithWidgets(text, 4000, naiveChunk)).toEqual([text])
  })

  it("puts at most one widget in each message", () => {
    const first = widget("<p>1</p>", "one")
    const second = widget("<p>2</p>", "two")
    const chunks = chunkInlineMarkdownWithWidgets(`A\n\n${first}\n\nB\n\n${second}\n\nC`, 4000, naiveChunk)
    expect(chunks).toEqual([`A\n\n${first}`, `B\n\n${second}\n\nC`])
    for (const chunk of chunks) expect(findInlineWidgetSpans(chunk).length).toBeLessThanOrEqual(1)
  })

  it("chunks long prose around a widget and keeps its lead paragraph with it", () => {
    const prose = "word ".repeat(30).trim()
    const block = widget("<p>x</p>")
    const chunks = chunkInlineMarkdownWithWidgets(`${prose}\n\nLead\n\n${block}`, 60, naiveChunk)
    expect(chunks.at(-1)).toBe(`Lead\n\n${block}`)
    expect(chunks.slice(0, -1).join("")).toBe(prose)
  })

  it("keeps an unclosed widget whole instead of chunking inside it", () => {
    const text = `Intro\n\n<iframe title="x">\n${"<p>x</p>\n\n".repeat(20)}`
    const chunks = chunkInlineMarkdownWithWidgets(text, 50, naiveChunk)
    expect(chunks).toHaveLength(1)
    expect(chunks[0]!.startsWith("Intro\n\n<iframe")).toBe(true)
  })

  it("splits messages by widget without length chunking", () => {
    const long = "x".repeat(10_000)
    expect(splitInlineWidgetMessages(long)).toEqual([long])
    const first = widget("<p>1</p>", "one")
    const second = widget("<p>2</p>", "two")
    expect(splitInlineWidgetMessages(`${first}\n\n${second}`)).toEqual([first, second])
  })
})

describe("widget stream holdback", () => {
  it("holds an unclosed widget and partially streamed opener lines", () => {
    expect(splitInlineWidgetStreamTail("Intro\n\n<iframe title=\"x\">\n<div>")).toEqual({
      ready: "Intro",
      held: "<iframe title=\"x\">\n<div>",
    })
    expect(splitInlineWidgetStreamTail("Intro\n<ifr")).toEqual({ ready: "Intro", held: "<ifr" })
    expect(splitInlineWidgetStreamTail("Intro\n<iframe title=\"Q")).toEqual({ ready: "Intro", held: "<iframe title=\"Q" })
    expect(splitInlineWidgetStreamTail("a < b")).toEqual({ ready: "a < b", held: "" })
    expect(splitInlineWidgetStreamTail("```\n<ifr")).toEqual({ ready: "```\n<ifr", held: "" })
    const complete = `Intro\n\n${widget("<p>x</p>")}`
    expect(splitInlineWidgetStreamTail(complete)).toEqual({ ready: complete, held: "" })
  })

  it("never streams a half-written widget across blocks", () => {
    const state = { held: "" }
    const blocks = [
      "Revenue grew.\n\n<iframe title=\"Q3\" id=\"q3\" height=\"300\">\n<div class=\"card\">",
      "<p>Chart</p>",
      "</div>\n</iframe>\n\nDone.",
    ]
    const sent = blocks.map((block) => takeInlineWidgetStreamText(state, block, { flush: false }))
    expect(sent).toEqual([
      "Revenue grew.",
      "",
      "<iframe title=\"Q3\" id=\"q3\" height=\"300\">\n<div class=\"card\">\n<p>Chart</p>\n</div>\n</iframe>\n\nDone.",
    ])
    expect(state.held).toBe("")
  })

  it("flushes held text as is", () => {
    const state = { held: "" }
    expect(takeInlineWidgetStreamText(state, "<iframe title=\"x\">\n<p>", { flush: false })).toBe("")
    expect(takeInlineWidgetStreamText(state, "", { flush: true })).toBe("<iframe title=\"x\">\n<p>")
    expect(state.held).toBe("")
  })
})

describe("building widget messages", () => {
  it("escapes attribute values", () => {
    expect(escapeInlineWidgetAttribute(`a "b" & <c>`)).toBe("a &quot;b&quot; &amp; &lt;c&gt;")
    const text = buildInlineWidgetMarkdown({ html: "<p>x</p>", title: `Q3 "net" <rev> & co\nnext` })
    expect(text).toBe(
      `<iframe title="Q3 &quot;net&quot; &lt;rev&gt; &amp; co next" id="q3-net-rev-co-next" height="400">\n<p>x</p>\n</iframe>`,
    )
    expect(text.split("\n")[0]).not.toMatch(/[\r\n]/)
  })

  it("derives ids and clamps height", () => {
    expect(deriveInlineWidgetId("Café — Q3 Revenue!")).toBe("cafe-q3-revenue")
    expect(deriveInlineWidgetId("!!!")).toBe("widget")
    expect(deriveInlineWidgetId("x".repeat(100))).toHaveLength(64)
    expect(buildInlineWidgetMarkdown({ html: "<p>x</p>", height: 5 })).toContain('title="HTML preview" id="html-preview" height="80"')
    expect(buildInlineWidgetMarkdown({ html: "<p>x</p>", height: 9999, id: "a.b:c" })).toContain('id="a.b:c" height="2000"')
    expect(() => buildInlineWidgetMarkdown({ html: "<p>x</p>", id: "bad id" })).toThrow(InlineWidgetError)
  })

  it("rejects HTML Inline would cut short or refuse", () => {
    expect(() => buildInlineWidgetMarkdown({ html: "<p>a</p>\n</iframe>\n<p>b</p>" })).toThrow(/<\/iframe/)
    expect(() => buildInlineWidgetMarkdown({ html: "<p>a</IFRAME >" })).toThrow(/<\/iframe/)
    expect(() => buildInlineWidgetMarkdown({ html: "<iframe src=x></iframe>" })).toThrow(InlineWidgetError)
    expect(() => buildInlineWidgetMarkdown({ html: "  " })).toThrow(/empty/)
    expect(() => buildInlineWidgetMarkdown({ html: "é".repeat(140_000) })).toThrow(/bytes/)
    expect(() => buildInlineWidgetMarkdown({ html: "x".repeat(INLINE_MESSAGE_MAX_UTF16_UNITS) })).toThrow(/UTF-16/)
  })
})

describe("OpenClaw widget documents", () => {
  const bridge = (name: string) => `<script>(()=>{if(!window.parent||window.parent===window)return;/*${name}*/})();</script>`
  const wrap = (code: string, trailing = false) =>
    `<!doctype html>\n<html><head><meta charset="utf-8"><title>T</title><style>:root{--text:#000}</style></head>` +
    `<body>${bridge("widget")}${bridge("theme")}${trailing ? "" : bridge("size")}${code}${trailing ? bridge("size") : ""}</body></html>`

  it("keeps only the agent's widget code", () => {
    const code = `<div class="card">Hi</div>\n<script>document.title = "x"</script>`
    expect(extractOpenClawWidgetSource(wrap(code))).toBe(code)
    expect(extractOpenClawWidgetSource(wrap(code, true))).toBe(code)
    expect(extractOpenClawWidgetSource("<div>raw</div>")).toBe("<div>raw</div>")
  })

  it("adds the OpenClaw theme and prompt compatibility prelude", () => {
    const html = buildInlineWidgetHtmlFromOpenClaw(wrap("<p>x</p>"))
    expect(html).toBe(`${OPENCLAW_WIDGET_COMPAT_PRELUDE}\n<p>x</p>`)
    expect(buildInlineWidgetMarkdown({ html })).toContain("<p>x</p>\n</iframe>")
    expect(buildInlineWidgetHtmlFromOpenClaw(wrap(""))).toBe("")
  })
})
