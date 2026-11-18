// @vitest-environment happy-dom
import { renderToStaticMarkup } from "react-dom/server"
import { describe, expect, it } from "vitest"
import { buildTextDocument } from "../text/build"
import type { EntityInput } from "../text/types"
import { MessageText, type MessageTextProps } from "./MessageText"

// One document with every node kind: paragraph with a line break, mention,
// web link, bot command, marks, code block, quote, display math, thread
// reference, inline math.
const text = "Hi @ada see https://example.com and /help\nsecond line **b**\n\nconst x = 1\n\n> quoted line\n\n$$E=mc^2$$\n\nend #t math x^2 z"
const entities = [
  { type: "mention", offset: 3, length: 4, userId: "7" },
  { type: "url", offset: 12, length: 19 },
  { type: "botCommand", offset: 36, length: 5 },
  { type: "bold", offset: 54, length: 5 },
  { type: "italic", offset: 42, length: 6 },
  { type: "pre", offset: 61, length: 11, language: "ts" },
  { type: "blockquote", offset: 74, length: 13 },
  { type: "math", offset: 89, length: 10, display: true },
  { type: "thread", offset: 105, length: 2, chatId: "9" },
  { type: "math", offset: 113, length: 3 },
  { type: "underline", offset: 117, length: 1 },
] as unknown as EntityInput[]
const doc = buildTextDocument(text, entities)
const classNames = { root: "r", paragraph: "p", bold: "b", link: "l" }

const markup = (props: Partial<MessageTextProps> = {}) =>
  renderToStaticMarkup(<MessageText document={doc} classNames={classNames} {...props} />)

/** The default output, captured before the inline variant was added. */
const baseline = "<div class=\"r\" data-kind=\"messageText\" dir=\"ltr\"><p class=\"p\" data-kind=\"paragraph\" dir=\"ltr\">Hi <span data-kind=\"mention\" data-mention=\"user\" data-user-id=\"7\">@ada</span> see <a class=\"l\" data-kind=\"link\" data-link-kind=\"web\" href=\"https://example.com/\" rel=\"noopener noreferrer\" target=\"_blank\">https://example.com</a> and <span data-kind=\"botCommand\" data-command=\"/help\">/help</span>\n<em data-mark=\"italic\">second</em> line <strong class=\"b\" data-mark=\"bold\">**b**</strong></p><pre data-kind=\"codeBlock\" data-language=\"ts\" dir=\"ltr\"><code>const x = 1</code></pre><blockquote data-kind=\"quote\" dir=\"ltr\"><p class=\"p\" data-kind=\"paragraph\" dir=\"ltr\">&gt; quoted line</p></blockquote><code data-kind=\"mathBlock\" dir=\"ltr\">$$E=mc^2$$</code><p class=\"p\" data-kind=\"paragraph\" dir=\"ltr\">end <span data-kind=\"threadRef\" data-chat-id=\"9\">#t</span> math <code data-kind=\"math\">x^2</code> <u data-mark=\"underline\">z</u></p></div>"

describe("MessageText default variant", () => {
  it("is byte-for-byte unchanged", () => {
    expect(markup()).toBe(baseline)
    expect(markup({ inline: false })).toBe(baseline)
  })
})

describe("MessageText inline variant", () => {
  const html = markup({ inline: true })
  const host = (() => {
    const parsed = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html")
    return parsed.body
  })()

  it("renders phrasing content only", () => {
    expect(host.querySelector("div, p, pre, blockquote, ul, ol, table, section")).toBeNull()
    const root = host.firstElementChild
    expect(root?.tagName).toBe("SPAN")
    expect(root?.getAttribute("data-kind")).toBe("messageText")
    expect(root?.getAttribute("class")).toBe("r")
  })

  it("renders paragraphs as spans with line breaks as br", () => {
    const paragraphs = host.querySelectorAll('[data-kind="paragraph"]')
    expect(Array.from(paragraphs, (node) => node.tagName)).toEqual(["SPAN", "SPAN", "SPAN"])
    const first = paragraphs[0]
    expect(first?.getAttribute("class")).toBe("p")
    expect(first?.querySelectorAll("br")).toHaveLength(1)
    expect(first?.textContent).toBe("Hi @ada see https://example.com and /helpsecond line **b**")
  })

  it("keeps inline nodes as in the default variant", () => {
    expect(host.querySelector('[data-kind="mention"]')?.textContent).toBe("@ada")
    const link = host.querySelector('a[data-kind="link"]')
    expect(link?.getAttribute("href")).toBe("https://example.com/")
    expect(link?.getAttribute("rel")).toBe("noopener noreferrer")
    expect(host.querySelector('[data-kind="botCommand"]')?.getAttribute("data-command")).toBe("/help")
    expect(host.querySelector('[data-kind="threadRef"]')?.getAttribute("data-chat-id")).toBe("9")
    expect(host.querySelector('code[data-kind="math"]')?.textContent).toBe("x^2")
    expect(host.querySelector("strong")?.textContent).toBe("**b**")
    expect(host.querySelector("em")?.textContent).toBe("second")
    expect(host.querySelector("u")?.textContent).toBe("z")
  })

  it("degrades code blocks, quotes and display math to inline forms", () => {
    const code = host.querySelector('[data-kind="codeBlock"]')
    expect(code?.tagName).toBe("CODE")
    expect(code?.getAttribute("data-language")).toBe("ts")
    expect(code?.getAttribute("dir")).toBe("ltr")
    expect(code?.textContent).toBe("const x = 1")
    const quote = host.querySelector('[data-kind="quote"]')
    expect(quote?.tagName).toBe("SPAN")
    expect(quote?.textContent).toBe("> quoted line")
    const math = host.querySelector('[data-kind="mathBlock"]')
    expect(math?.tagName).toBe("CODE")
    expect(math?.textContent).toBe("$$E=mc^2$$")
  })

  it("separates blocks with one br each", () => {
    expect(host.querySelectorAll('br[data-kind="blockBreak"]')).toHaveLength(4)
  })

  it("breaks multi-line code and multi-paragraph quotes with br", () => {
    const source = "a\nb\n\n> one\n>\n> two"
    const multi = buildTextDocument(source, [
      { type: "pre", offset: 0, length: 3 },
      { type: "blockquote", offset: 5, length: 13 },
    ] as unknown as EntityInput[])
    const out = renderToStaticMarkup(<MessageText document={multi} inline />)
    expect(out).toContain('<code data-kind="codeBlock" dir="ltr">a<br/>b</code>')
    expect(out).not.toMatch(/<(div|p|pre|blockquote)[ >]/)
  })

  it("makes interactive nodes keyboard-reachable when handlers are given", () => {
    const out = renderToStaticMarkup(<MessageText document={doc} inline onMention={() => {}} />)
    expect(out).toContain('data-kind="mention" data-mention="user" data-user-id="7" role="link" tabindex="0"')
  })
})
