// @vitest-environment happy-dom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { buildTextDocument } from "../text/build"
import { updateTextDocument } from "../text/reuse"
import type { EntityInput, TextDocument } from "../text/types"
import { MessageText, type MessageTextProps } from "./MessageText"

const e = (type: EntityInput["type"], offset: number, length: number, extra: Partial<EntityInput> = {}): EntityInput =>
  ({ type, offset, length, ...extra }) as EntityInput

beforeAll(() => {
  ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true
})

let root: Root | undefined
let host: HTMLElement | undefined

const render = (props: MessageTextProps): HTMLElement => {
  if (!host) {
    host = document.createElement("div")
    document.body.append(host)
    root = createRoot(host)
  }
  act(() => root?.render(<MessageText {...props} />))
  return host
}

afterEach(() => {
  act(() => root?.unmount())
  host?.remove()
  root = undefined
  host = undefined
})

const one = (container: HTMLElement, selector: string): HTMLElement => {
  const found = container.querySelector<HTMLElement>(selector)
  if (!found) throw new Error(`no ${selector} in ${container.innerHTML}`)
  return found
}

describe("MessageText elements", () => {
  it("renders marks as semantic elements, nested in canonical order", () => {
    const text = "b i u s h c all"
    const doc = buildTextDocument(text, [
      e("bold", 0, 1),
      e("italic", 2, 1),
      e("underline", 4, 1),
      e("strikethrough", 6, 1),
      e("highlight", 8, 1),
      e("code", 10, 1),
      e("bold", 12, 3),
      e("italic", 12, 3),
      e("code", 12, 3),
    ])
    const view = render({ document: doc })
    expect(one(view, "strong").textContent).toBe("b")
    expect(one(view, "em").textContent).toBe("i")
    expect(one(view, "u").textContent).toBe("u")
    expect(one(view, "s").textContent).toBe("s")
    expect(one(view, "mark").textContent).toBe("h")
    expect(view.querySelectorAll("code")[0]?.textContent).toBe("c")
    const nested = view.querySelectorAll("strong")[1]
    expect(nested?.firstElementChild?.tagName).toBe("EM")
    expect(nested?.firstElementChild?.firstElementChild?.tagName).toBe("CODE")
    expect(one(view, "p").textContent).toBe(text)
  })

  it("renders paragraphs, code blocks, quotes and math", () => {
    const text = "intro\nconst x = 1\nquoted\nx^2 and y"
    const doc = buildTextDocument(text, [
      e("pre", 6, 11, { language: "ts" }),
      e("blockquote", 18, 6),
      e("math", 25, 3),
    ])
    const view = render({ document: doc })
    const blocks = [...one(view, "[data-kind=messageText]").children].map((el) => el.tagName)
    expect(blocks).toEqual(["P", "PRE", "BLOCKQUOTE", "P"])
    const pre = one(view, "pre")
    expect(pre.getAttribute("data-language")).toBe("ts")
    expect(pre.getAttribute("dir")).toBe("ltr")
    expect(one(pre, "code").textContent).toBe("const x = 1")
    expect(one(view, "blockquote > p").textContent).toBe("quoted")
    expect(one(view, "[data-kind=math]").textContent).toBe("x^2")
  })

  it("renders safe links with rel and the normalized URL only", () => {
    const text = "web mail phone app"
    const doc = buildTextDocument(text, [
      e("textUrl", 0, 3, { url: "HTTPS://Example.com/a" }),
      e("email", 4, 4),
      e("textUrl", 9, 5, { url: "tel:+15551234567" }),
      e("textUrl", 15, 3, { url: "https://inline.chat/c/7" }),
    ])
    // The email entity's text "mail" is not an address, so it stays text.
    const view = render({ document: doc })
    const links = [...view.querySelectorAll("a")]
    expect(links.map((a) => [a.textContent, a.getAttribute("href"), a.getAttribute("rel"), a.getAttribute("target")])).toEqual([
      ["web", "https://example.com/a", "noopener noreferrer", "_blank"],
      ["phone", "tel:+15551234567", "noopener noreferrer", null],
      ["app", "https://inline.chat/c/7", "noopener noreferrer", null],
    ])
    expect(links.map((a) => a.getAttribute("data-link-kind"))).toEqual(["web", "phone", "app"])
  })

  it("renders an unsafe URL as plain text", () => {
    const text = "click here or there"
    const doc = buildTextDocument(text, [
      e("textUrl", 0, 10, { url: "javascript:alert(document.cookie)" }),
      e("textUrl", 14, 5, { url: "data:text/html,<script>alert(1)</script>" }),
      e("url", 0, 5),
    ])
    const view = render({ document: doc })
    expect(view.querySelector("a")).toBeNull()
    expect(view.textContent).toBe(text)
    expect(view.innerHTML).not.toContain("javascript")
    expect(view.innerHTML).not.toContain("script>")
  })

  it("renders text as text, never as markup", () => {
    const text = '<img src=x onerror="alert(1)"> & <b>bold</b>'
    const doc = buildTextDocument(text, [e("bold", 0, 5)])
    const view = render({ document: doc })
    expect(view.querySelector("img")).toBeNull()
    expect(view.querySelector("b")).toBeNull()
    expect(view.textContent).toBe(text)
  })

  it("sets dir from the word-majority rule, auto without letters", () => {
    const persian = "\u0627\u06cc\u0646 \u06cc\u06a9 \u067e\u06cc\u0627\u0645 \u0641\u0627\u0631\u0633\u06cc \u0627\u0633\u062a"
    const doc = buildTextDocument(`Claude Code ${persian}\n\n123`)
    const view = render({ document: doc })
    const paragraphs = [...view.querySelectorAll("p")]
    expect(one(view, "[data-kind=messageText]").getAttribute("dir")).toBe("rtl")
    expect(paragraphs.map((p) => p.getAttribute("dir"))).toEqual(["rtl", "auto"])
  })

  it("applies class names and data attributes", () => {
    const doc = buildTextDocument("hi @Ada", [e("bold", 0, 2), e("mention", 3, 4, { userId: "9" as never })])
    const view = render({ document: doc, classNames: { root: "r", paragraph: "p", bold: "b", mention: "m" } })
    expect(one(view, "[data-kind=messageText]").className).toBe("r")
    expect(one(view, "p").className).toBe("p")
    expect(one(view, "strong").className).toBe("b")
    const mention = one(view, "[data-kind=mention]")
    expect(mention.className).toBe("m")
    expect(mention.getAttribute("data-user-id")).toBe("9")
    expect(mention.getAttribute("role")).toBeNull()
  })

  it("ignores a block kind it does not know", () => {
    const doc = buildTextDocument("hello")
    const extended = {
      ...doc,
      blocks: [...doc.blocks, { kind: "photo", key: "photo1", start: 0, end: 0, blankLinesBefore: 0 }],
    } as unknown as TextDocument
    const view = render({ document: extended })
    expect(view.textContent).toBe("hello")
  })
})

describe("MessageText handlers", () => {
  it("calls mention, thread and bot command handlers on click and Enter", () => {
    const text = "@Ada #plan /help"
    const doc = buildTextDocument(text, [
      e("mention", 0, 4, { userId: "9" as never }),
      e("thread", 5, 5, { chatId: "4" as never }),
      e("botCommand", 11, 5),
    ])
    const onMention = vi.fn()
    const onThreadRef = vi.fn()
    const onBotCommand = vi.fn()
    const view = render({ document: doc, onMention, onThreadRef, onBotCommand })

    const mention = one(view, "[data-kind=mention]")
    expect(mention.getAttribute("role")).toBe("link")
    expect(mention.tabIndex).toBe(0)
    act(() => mention.click())
    expect(onMention).toHaveBeenCalledWith({ kind: "user", userId: "9" }, expect.anything())

    act(() => {
      one(view, "[data-kind=threadRef]").dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }))
    })
    expect(onThreadRef).toHaveBeenCalledWith({ kind: "chat", chatId: "4" }, expect.anything())

    act(() => one(view, "[data-kind=botCommand]").click())
    expect(onBotCommand).toHaveBeenCalledWith(expect.objectContaining({ command: "/help" }), expect.anything())
  })

  it("routes in-app links to the handler and prevents navigation", () => {
    const doc = buildTextDocument("open", [e("textUrl", 0, 4, { url: "inline://chat/5/message/2" })])
    const onAppLink = vi.fn()
    const view = render({ document: doc, onAppLink })
    const event = new MouseEvent("click", { bubbles: true, cancelable: true })
    act(() => {
      one(view, "a").dispatchEvent(event)
    })
    expect(event.defaultPrevented).toBe(true)
    expect(onAppLink).toHaveBeenCalledWith(expect.objectContaining({ kind: "app", host: "chat", path: ["5", "message", "2"] }), expect.anything())
  })

  it("lets an external link handler take over", () => {
    const doc = buildTextDocument("site", [e("textUrl", 0, 4, { url: "https://example.com" })])
    const onExternalLink = vi.fn((_link, event: { preventDefault: () => void }) => event.preventDefault())
    const view = render({ document: doc, onExternalLink })
    const event = new MouseEvent("click", { bubbles: true, cancelable: true })
    act(() => {
      one(view, "a").dispatchEvent(event)
    })
    expect(onExternalLink).toHaveBeenCalledWith(expect.objectContaining({ kind: "web", href: "https://example.com/" }), expect.anything())
    expect(event.defaultPrevented).toBe(true)
  })
})

describe("MessageText under streaming", () => {
  it("reuses the earlier DOM nodes when text is appended", () => {
    let doc = updateTextDocument(undefined, "First paragraph, done.\n\nSecond one is str", [e("bold", 0, 5)])
    const view = render({ document: doc })
    const [firstP, secondP] = [...view.querySelectorAll("p")]
    const firstStrong = one(view, "strong")
    const firstText = firstP?.lastChild

    doc = updateTextDocument(doc, "First paragraph, done.\n\nSecond one is streaming in", [e("bold", 0, 5)])
    render({ document: doc })
    const after = [...view.querySelectorAll("p")]
    expect(after[0]).toBe(firstP)
    expect(after[1]).toBe(secondP)
    expect(one(view, "strong")).toBe(firstStrong)
    expect(after[0]?.lastChild).toBe(firstText)
    expect(after[1]?.textContent).toBe("Second one is streaming in")

    doc = updateTextDocument(doc, "First paragraph, done.\n\nSecond one is streaming in.\n\nThird", [e("bold", 0, 5)])
    render({ document: doc })
    const third = [...view.querySelectorAll("p")]
    expect(third).toHaveLength(3)
    expect(third[0]).toBe(firstP)
    expect(third[1]).toBe(secondP)
  })
})
