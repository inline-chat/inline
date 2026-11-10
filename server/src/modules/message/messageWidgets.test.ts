import { describe, expect, test } from "bun:test"
import { AgentGrantRequirement, type BlockContent } from "@inline-chat/protocol/core"
import { validateBlockContent } from "./blockContent"
import { extractMarkdownWidget, MessageWidgetError, validateWidgetCall, widgetHtmlProblem } from "./messageWidgets"

const encode = (value: string) => new TextEncoder().encode(value)

describe("AFM preview extraction", () => {
  test("reads native attributes and keeps the payload literal", () => {
    const extracted = extractMarkdownWidget("Intro\n\n<iframe title=\"A &amp; B\" id=\"chart\" height=\"9000\" sandbox>\n<p>*not* markdown</p>\n\n<p>x</p>\n</iframe>\n\nOutro")
    expect(extracted?.widget).toEqual({ widgetId: "chart", title: "A & B", html: "<p>*not* markdown</p>\n\n<p>x</p>", height: 2_000 })
    expect(extracted?.markdown).toBe("Intro\n\nA \\& B\n\nOutro")
    expect(extracted?.markdown.slice(extracted.titleStart, extracted.titleEnd)).toBe("A \\& B")
  })

  test("defaults the id and title, and separates the title from adjacent lines", () => {
    const extracted = extractMarkdownWidget("Before\n<iframe><b>x</b></iframe>\nAfter")
    expect(extracted?.widget).toEqual({ widgetId: "widget", title: "HTML preview", html: "<b>x</b>" })
    expect(extracted?.markdown).toBe("Before\n\nHTML preview\n\nAfter")
  })

  test("ignores previews in code fences and messages without one", () => {
    expect(extractMarkdownWidget("```html\n<iframe>x</iframe>\n```")).toBeUndefined()
    expect(extractMarkdownWidget("plain text with <iframe> mid-line")).toBeUndefined()
  })

  test("rejects a second preview, a missing closer, trailing text and a bad id", () => {
    for (const source of [
      "<iframe>a</iframe>\n<iframe>b</iframe>",
      "<iframe title=\"x\">\nno closer",
      "<iframe>a</iframe> trailing",
      "<iframe id=\"has space\">a</iframe>",
      "<iframe height=\"tall\">a</iframe>",
    ]) {
      expect(() => extractMarkdownWidget(source)).toThrow(MessageWidgetError)
    }
  })
})

describe("widget rules", () => {
  test("HTML problems name the rule and line", () => {
    expect(widgetHtmlProblem("<div>ok</div>")).toBeUndefined()
    expect(widgetHtmlProblem("<style>\n.a { height: 100dvh }\n</style>")).toContain("line 2")
    expect(widgetHtmlProblem("<iframe src=x></iframe>")).toContain("nested iframe")
    expect(widgetHtmlProblem("<input name=k type='password'>")).toContain("password")
    expect(widgetHtmlProblem("x".repeat(256 * 1024 + 1))).toContain("256 KiB")
    expect(widgetHtmlProblem("  ")).toBe("Widget HTML is empty")
  })

  test("calls carry a valid name and UTF-8 JSON", () => {
    expect(validateWidgetCall({ name: " pick ", payload: encode("{\"a\":1}") })).toEqual({
      call: { name: "pick", payload: encode("{\"a\":1}") },
      payload: { a: 1 },
    })
    expect(validateWidgetCall({ name: "ping", payload: new Uint8Array() }).payload).toBeUndefined()
    expect(() => validateWidgetCall({ name: "bad name", payload: new Uint8Array() })).toThrow(MessageWidgetError)
    expect(() => validateWidgetCall({ name: "a", payload: encode("{") })).toThrow(MessageWidgetError)
    expect(() => validateWidgetCall({ name: "a", payload: new Uint8Array([0xff]) })).toThrow(MessageWidgetError)
    expect(() => validateWidgetCall({ name: "a", payload: encode(`"${"x".repeat(4096)}"`) })).toThrow(MessageWidgetError)
  })

  test("a message holds one widget whose ID no form shares", () => {
    const text = "Title"
    const widget = (widgetId: string) => ({
      kind: {
        oneofKind: "widget" as const,
        widget: { widgetId, title: { offset: 0n, length: 5n }, html: "<b>x</b>", images: [], requiredGrant: AgentGrantRequirement.NONE },
      },
    })
    const content = (blocks: BlockContent["blocks"]): BlockContent => ({ blocks })
    expect(() => validateBlockContent(text, content([widget("w")]))).not.toThrow()
    expect(() => validateBlockContent(text, content([widget("w"), widget("v")]))).toThrow("Too many widgets")
    expect(() => validateBlockContent(text, content([{
      kind: { oneofKind: "widget", widget: { ...widget("w").kind.widget, height: 40 } },
    }]))).toThrow("80 to 2000")
    expect(() => validateBlockContent(text, content([{
      kind: { oneofKind: "form", form: { formId: "w", requiredGrant: 0, closed: false, fields: [{
        fieldId: "f", label: { offset: 0n, length: 5n }, required: false, kind: { oneofKind: "toggle", toggle: { defaultValue: false } },
      }] } },
    }, widget("w")]))).toThrow("Duplicate widget id")
  })
})
