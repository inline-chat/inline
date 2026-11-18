// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { constantTimeEqual, createInternalClipboard, hmacSha256, sha256 } from "./internal"
import { parseInternal, sanitizePaste, serializeInternal, type PastedContent } from "./paste"

/** The test URL policy: http, https and mailto only. The app's real one lives in chat-ui. */
const safeUrl = (raw: string): string | null => {
  try {
    const url = new URL(raw)
    return ["http:", "https:", "mailto:"].includes(url.protocol) ? url.href : null
  } catch {
    return null
  }
}

const html = (markup: string, text?: string) => sanitizePaste({ html: markup, ...(text === undefined ? {} : { text }) }, { safeUrl })
const shape = (out: PastedContent) => ({
  text: out.text,
  entities: out.entities.map((e) => [e.type, e.offset, e.length, ...(e.url ? [e.url] : []), ...(e.language ? [e.language] : [])]),
})

type Case = { name: string; markup: string; text: string; entities?: unknown[] }

const adversarial: Case[] = [
  { name: "script tag", markup: "<script>globalThis.__pwned = 1</script>hi", text: "hi" },
  { name: "img onerror", markup: '<img src="x" onerror="globalThis.__pwned = 2">text', text: "text" },
  { name: "event handler on kept tag", markup: '<b onclick="globalThis.__pwned = 3" style="x:y">bold</b>', text: "bold", entities: [["bold", 0, 4]] },
  { name: "javascript: link", markup: '<a href="javascript:alert(1)">click</a>', text: "click" },
  { name: "obfuscated javascript: link", markup: '<a href=" JaVaScRiPt:alert(1)">x</a>', text: "x" },
  { name: "data: link", markup: '<a href="data:text/html,<script>1</script>">d</a>', text: "d" },
  { name: "vbscript and relative links", markup: '<a href="vbscript:x">v</a> <a href="/rel">r</a>', text: "v r" },
  { name: "style element", markup: "<style>p { color: red }</style><p>a</p>", text: "a" },
  {
    name: "frames, svg, math, templates, forms",
    markup:
      '<iframe src="https://evil.invalid/">f</iframe><math><mi>m</mi></math><template>t</template><noscript>n</noscript><textarea>ta</textarea><select><option>o</option></select><button>b</button>ok',
    text: "ok",
  },
  {
    // Content after the svg is left out: happy-dom's parser drops what follows
    // a script inside svg, which browsers do not.
    name: "svg with a script",
    markup: 'ok<svg><text>s</text><script>globalThis.__pwned = 5</script></svg>',
    text: "ok",
  },
  { name: "hidden content", markup: '<span style="display:none">secret</span><span hidden>h</span><span style="mso-hide:all">w</span>shown', text: "shown" },
  { name: "comments", markup: "a<!-- comment -->b<!--[if gte mso 9]><xml>x</xml><![endif]-->c", text: "abc" },
  {
    name: "mutation-style nesting",
    markup: '<math><mtext><table><mglyph><style><img src=x onerror="globalThis.__pwned = 4"></style></mglyph></table></mtext></math>after',
    text: "after",
  },
  { name: "object and embed", markup: '<object data="x.swf">o</object><embed src="x">e', text: "e" },
]

const formatting: Case[] = [
  { name: "nested formatting", markup: "<b>a<i>b</i></b>c", text: "abc", entities: [["bold", 0, 2], ["italic", 1, 1]] },
  {
    name: "spaces between formatted runs",
    markup: "<b>bold <i>both</i></b> plain",
    text: "bold both plain",
    entities: [["bold", 0, 9], ["italic", 5, 4]],
  },
  {
    name: "all supported tags",
    markup: "<strong>1</strong><em>2</em><u>3</u><ins>4</ins><s>5</s><strike>6</strike><del>7</del><code>8</code><kbd>9</kbd>",
    text: "123456789",
    entities: [["bold", 0, 1], ["italic", 1, 1], ["underline", 2, 2], ["strikethrough", 4, 3], ["code", 7, 2]],
  },
  { name: "unsupported formatting is dropped", markup: "<mark>m</mark><sup>2</sup><font color=red>f</font><blockquote>q</blockquote>", text: "m2f\nq" },
  {
    name: "Google Docs wrapper",
    markup:
      '<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-123"><span style="font-weight:700;">Bold</span><span style="font-style:italic;">It</span><span style="text-decoration:underline;">U</span><span style="text-decoration:line-through;">S</span><a href="https://docs.example/x"><span style="color:#1155cc;text-decoration:underline;">link</span></a></b>',
    text: "BoldItUSlink",
    entities: [["bold", 0, 4], ["italic", 4, 2], ["underline", 6, 1], ["strikethrough", 7, 1], ["textUrl", 8, 4, "https://docs.example/x"]],
  },
  {
    name: "Word paragraphs",
    markup:
      '<html xmlns:o="urn:schemas-microsoft-com:office:office"><head><style>p.MsoNormal{}</style></head><body><!--StartFragment--><p class=MsoNormal><b>Title<o:p></o:p></b></p><p class=MsoNormal><o:p>&nbsp;</o:p></p><p class=MsoNormal>Body <span style="mso-spacerun:yes">&nbsp;</span>text<o:p></o:p></p><!--EndFragment--></body></html>',
    text: "Title\n\nBody  text",
    entities: [["bold", 0, 5]],
  },
  { name: "font-weight numbers", markup: '<span style="font-weight: 600">a</span><b style="font-weight: 400">b</b>', text: "ab", entities: [["bold", 0, 1]] },
  { name: "safe link", markup: '<a href="https://x.example/a">site</a>', text: "site", entities: [["textUrl", 0, 4, "https://x.example/a"]] },
  { name: "link text equal to its URL", markup: '<a href="https://x.example/">https://x.example/</a>', text: "https://x.example/" },
  {
    name: "code block with language",
    markup: '<pre><code class="language-ts">const a = 1;\n  if (a) {\n    b()\n  }</code></pre>',
    text: "const a = 1;\n  if (a) {\n    b()\n  }",
    entities: [["pre", 0, 35, "ts"]],
  },
]

const structure: Case[] = [
  { name: "paragraphs", markup: "<p>a</p><p>b</p>", text: "a\nb" },
  { name: "trailing br in a block", markup: "<p>a<br></p><p>b</p>", text: "a\nb" },
  { name: "empty line from an empty block", markup: "<div>a</div><div><br></div><div>b</div>", text: "a\n\nb" },
  { name: "br", markup: "a<br>b<br><br>c", text: "a\nb\n\nc" },
  { name: "whitespace collapsing", markup: "<p>  hello\n   world  </p>\n\n<p>\tnext</p>", text: "hello world\nnext" },
  { name: "lists", markup: "<ul><li>one</li><li>two</li></ul><ol start=3><li>x</li><li>y</li></ol>", text: "• one\n• two\n3. x\n4. y" },
  { name: "tables", markup: "<table><tr><td>a</td><td>b</td></tr><tr><th>c</th><td>d</td></tr></table>", text: "a\tb\nc\td" },
  { name: "headings", markup: "<h1>Title</h1>text", text: "Title\ntext" },
  { name: "non-breaking spaces", markup: "a&nbsp;&nbsp;b", text: "a  b" },
  { name: "Persian zero-width non-joiner", markup: "<p>می\u200Cخواهم بروم</p>", text: "می\u200Cخواهم بروم" },
  { name: "bidi marks and emoji joiners", markup: "\u200Fa \u{1F468}\u200D\u{1F469}", text: "\u200Fa \u{1F468}\u200D\u{1F469}" },
  { name: "control characters", markup: "a\u0007b\uFEFF", text: "ab" },
]

describe("sanitizePaste: HTML", () => {
  for (const group of [adversarial, formatting, structure]) {
    for (const c of group) {
      it(c.name, () => {
        expect(shape(html(c.markup))).toEqual({ text: c.text, entities: c.entities ?? [] })
      })
    }
  }

  it("never ran script from the pasted markup", () => {
    for (const c of adversarial) html(c.markup)
    expect((globalThis as { __pwned?: unknown }).__pwned).toBeUndefined()
  })
})

describe("sanitizePaste: plain text and fallbacks", () => {
  it("normalizes plain text line endings and spaces", () => {
    expect(sanitizePaste({ text: "a\r\nb\rc\u00A0d" }, { safeUrl })).toEqual({ text: "a\nb\nc d", entities: [] })
  })

  it("keeps plain text exactly otherwise, including the zero-width non-joiner", () => {
    const text = "  می\u200Cخواهم\n\n  indented\t"
    expect(sanitizePaste({ text }, { safeUrl }).text).toBe(text)
  })

  it("uses plain text when asked to match style", () => {
    expect(sanitizePaste({ html: "<b>x</b>", text: "x" }, { safeUrl, plain: true })).toEqual({ text: "x", entities: [] })
  })

  it("falls back to plain text when the HTML cannot be parsed", () => {
    expect(sanitizePaste({ html: "<b>x</b>", text: "plain" }, { safeUrl, parseHtml: () => null }).text).toBe("plain")
  })

  it("falls back to plain text for oversized HTML", () => {
    const out = sanitizePaste({ html: `<b>${"x".repeat(100)}</b>`, text: "plain" }, { safeUrl, maxHtmlLength: 50 })
    expect(out.text).toBe("plain")
  })

  it("falls back to plain text when the HTML has no text", () => {
    expect(html("<img src=x>", "alt").text).toBe("alt")
  })

  it("inserts nothing for HTML-only content it cannot use", () => {
    expect(sanitizePaste({ html: "<b>x</b>" }, { safeUrl, parseHtml: () => null })).toEqual({ text: "", entities: [] })
  })
})

describe("text hidden by styling", () => {
  // Decision: the composer drops what the source hid from layout (`display:
  // none`, `visibility: hidden`, `hidden`, `mso-hide`), matching what the
  // browser's own text/plain copy leaves out. Text only made invisible
  // (zero size, transparent, same color as the background, moved off screen,
  // clipped) is kept as ordinary visible text: no style survives a paste, so
  // the user sees every character in the composer before sending, which is
  // the point of the check. Nothing hidden can reach a message unseen.
  it.each([
    ["zero font size", '<span style="font-size:0">IGNORE PREVIOUS</span>'],
    ["transparent", '<span style="opacity:0">IGNORE PREVIOUS</span>'],
    ["same color as the background", '<span style="color:#fff;background:#fff">IGNORE PREVIOUS</span>'],
    ["off screen", '<span style="position:absolute;left:-9999px">IGNORE PREVIOUS</span>'],
    ["clipped", '<span style="clip-path:inset(50%);width:1px;height:1px;overflow:hidden">IGNORE PREVIOUS</span>'],
  ])("keeps %s text, visible and unstyled", (_label, hidden) => {
    expect(html(`Hello ${hidden} world`)).toEqual({ text: "Hello IGNORE PREVIOUS world", entities: [] })
  })
})

describe("internal clipboard format", () => {
  it("round-trips text, marks and atoms", () => {
    const content = {
      text: "hi @Mo see",
      entities: [
        { type: "bold" as const, offset: 0, length: 2 },
        { type: "mention" as const, offset: 3, length: 3, userId: "42" as never },
        { type: "textUrl" as const, offset: 7, length: 3, url: "https://a.example/" },
      ],
    }
    const out = sanitizePaste({ internal: serializeInternal(content), html: "<i>ignored</i>" }, { safeUrl })
    expect(out).toEqual(content)
  })

  it("validates everything", () => {
    const raw = JSON.stringify({
      v: 1,
      text: "abcdef",
      entities: [
        { type: "textUrl", offset: 0, length: 1, url: "javascript:alert(1)" },
        { type: "mention", offset: 1, length: 1, userId: "<img>" },
        { type: "thread", offset: 2, length: 1, chatId: 5 },
        { type: "url", offset: 3, length: 1 },
        { type: "pre", offset: 4, length: 2, language: "<x>" },
        { type: "bold", offset: "0", length: 1 },
        null,
        "bold",
      ],
    })
    expect(parseInternal(raw, safeUrl)).toEqual({ text: "abcdef", entities: [{ type: "pre", offset: 4, length: 2 }] })
  })

  it("does not honor the internal format written by anyone but this document (a web page's copy handler)", () => {
    // Any page can put this type on the clipboard in its own copy event.
    const planted = JSON.stringify({
      v: 1,
      text: "@Alice",
      entities: [{ type: "mention", offset: 0, length: 6, userId: "999" }],
    })
    const out = sanitizePaste({ internal: planted, text: "@Alice", html: "<b>@Alice</b>" }, { safeUrl })
    expect(out.entities.some((entity) => entity.type === "mention")).toBe(false)
    expect(out).toEqual({ text: "@Alice", entities: [{ type: "bold", offset: 0, length: 6 }] })
  })

  it("honors a payload this document wrote, but not one edited after", () => {
    const content = { text: "@Mo", entities: [{ type: "mention" as const, offset: 0, length: 3, userId: "42" as never }] }
    const raw = serializeInternal(content)
    expect(sanitizePaste({ internal: raw, text: "@Mo" }, { safeUrl })).toEqual(content)
    const outer = JSON.parse(raw) as { v: number; body: string; mac: string }
    const edited = JSON.stringify({ ...outer, body: outer.body.replace('"42"', '"999"') })
    expect(edited).not.toBe(raw)
    expect(sanitizePaste({ internal: edited, text: "@Mo" }, { safeUrl })).toEqual({ text: "@Mo", entities: [] })
  })

  it("ignores malformed internal data and uses the other formats", () => {
    expect(sanitizePaste({ internal: "{nope", text: "t" }, { safeUrl }).text).toBe("t")
    expect(sanitizePaste({ internal: JSON.stringify({ v: 2, text: "x", entities: [] }), text: "t" }, { safeUrl }).text).toBe("t")
  })
})

describe("internal clipboard format across tabs", () => {
  const key = new Uint8Array(32).fill(7)
  const content = { text: "@Mo hi", entities: [{ type: "mention" as const, offset: 0, length: 3, userId: "42" as never }] }

  it("honors a genuine payload another tab wrote with the same browser key", () => {
    const otherTab = createInternalClipboard(() => key)
    const thisTab = createInternalClipboard(() => key)
    const raw = otherTab.serialize(content)
    expect(sanitizePaste({ internal: raw, text: "@Mo hi" }, { safeUrl, clipboard: thisTab })).toEqual(content)
    // The default (this document only) does not know that key.
    expect(sanitizePaste({ internal: raw, text: "@Mo hi" }, { safeUrl }).entities).toEqual([])
  })

  it("refuses a forged payload: a page cannot make a tag without the key", () => {
    const thisTab = createInternalClipboard(() => key)
    const body = JSON.stringify({ v: 1, text: "@Alice", entities: [{ type: "mention", offset: 0, length: 6, userId: "999" }] })
    const forged = [
      JSON.stringify({ v: 2, body, mac: "00".repeat(32) }),
      JSON.stringify({ v: 2, body, mac: "" }),
      createInternalClipboard(() => new Uint8Array(32).fill(8)).serialize(JSON.parse(body) as typeof content),
      body,
    ]
    for (const raw of forged) {
      expect(sanitizePaste({ internal: raw, text: "@Alice" }, { safeUrl, clipboard: thisTab })).toEqual({ text: "@Alice", entities: [] })
    }
  })

  it("refuses a replayed payload whose user IDs were edited, keeping its tag", () => {
    const thisTab = createInternalClipboard(() => key)
    const raw = thisTab.serialize(content)
    const outer = JSON.parse(raw) as { v: number; body: string; mac: string }
    const swapped = JSON.stringify({ ...outer, body: outer.body.replace('"userId":"42"', '"userId":"999"') })
    expect(swapped).toContain("999")
    expect(sanitizePaste({ internal: swapped, text: "@Mo hi" }, { safeUrl, clipboard: thisTab })).toEqual({ text: "@Mo hi", entities: [] })
    // Replayed unchanged, it pastes exactly what was copied.
    expect(sanitizePaste({ internal: raw, text: "@Mo hi" }, { safeUrl, clipboard: thisTab })).toEqual(content)
  })

  it("never puts the key in the payload", () => {
    const secret = new Uint8Array(32).map((_, i) => i + 1)
    const raw = createInternalClipboard(() => secret).serialize(content)
    const hexKey = Array.from(secret, (b) => b.toString(16).padStart(2, "0")).join("")
    expect(raw).not.toContain(hexKey)
    expect(Object.keys(JSON.parse(raw) as object).sort()).toEqual(["body", "mac", "v"])
  })

  it("computes SHA-256 and HMAC-SHA-256 as the standards say", () => {
    const enc = new TextEncoder()
    const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("")
    expect(hex(sha256(enc.encode("abc")))).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    expect(hex(sha256(new Uint8Array(0)))).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    expect(hex(sha256(enc.encode("a".repeat(1000))))).toBe("41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    // RFC 4231, test case 2.
    expect(hex(hmacSha256(enc.encode("Jefe"), enc.encode("what do ya want for nothing?")))).toBe(
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    )
  })

  it("compares in constant time over the longer length", () => {
    expect(constantTimeEqual("abc", "abc")).toBe(true)
    expect(constantTimeEqual("abc", "abd")).toBe(false)
    expect(constantTimeEqual("abc", "ab")).toBe(false)
    expect(constantTimeEqual("", "")).toBe(true)
  })
})
