import { afterEach, describe, expect, it, vi } from "vitest"
import { Window } from "happy-dom"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { createMessageResultsHtml, MESSAGE_RESULTS_MIME_TYPE, MESSAGE_RESULTS_RESOURCE_URI, registerMessageResultsUi } from "./message-results-ui"

const windows: Window[] = []
afterEach(async () => {
  await Promise.all(windows.splice(0).map((window) => window.happyDOM.close()))
})

function message(overrides: Record<string, unknown> = {}) {
  return { id: "10", chatId: "7", text: "Hello team", out: false, fromId: "4", date: "1790726400", media: null, ...overrides }
}

function result(overrides: Record<string, unknown> = {}) {
  return { structuredContent: {
    chat: { chatId: "7", title: "Launch", kind: "space_chat", space: { id: "3", name: "Inline" } },
    messages: [message()], nextOffsetId: null, content: "all", since: null, until: null, senderUserId: null,
    ...overrides,
  } }
}

function mount(initialize = true) {
  const window = new Window({ url: "https://mcp.inline.chat", settings: { enableJavaScriptEvaluation: true } })
  windows.push(window)
  const sent: Array<Record<string, any>> = []
  const parent = { postMessage: vi.fn((data: Record<string, any>) => sent.push(data)) }
  Object.defineProperty(window, "parent", { value: parent })
  const html = createMessageResultsHtml()
  // Execute exactly the inline bundle the MCP resource sends, using a real DOM.
  // No remote assets or tool data are evaluated as JavaScript.
  const script = html.match(/<script>([\s\S]+)<\/script>/)![1]!
  window.document.write(html.replace(/<script>[\s\S]+<\/script>/, ""))
  const fetch = vi.fn(() => { throw new Error("the card must not fetch") })
  Object.defineProperty(window, "fetch", { value: fetch })
  const timeouts = vi.spyOn(window, "setTimeout")
  window.eval(script)
  const notify = (method: string, params: unknown, source: unknown = parent) => window.dispatchEvent(new window.MessageEvent("message", {
    source: source as any, data: { jsonrpc: "2.0", method, params },
  }))
  const receive = (data: unknown) => window.dispatchEvent(new window.MessageEvent("message", { source: parent as any, data }))
  if (initialize) receive({ jsonrpc: "2.0", id: 1, result: { protocolVersion: "2026-01-26", hostContext: { theme: "light" } } })
  return { window, document: window.document, sent, notify, receive, fetch, parent, timeouts }
}

describe("message results card", () => {
  it("initializes the standard bridge and waits for data instead of inventing an empty result", () => {
    const card = mount(false)
    expect(card.sent).toEqual([{ jsonrpc: "2.0", id: 1, method: "ui/initialize", params: {
      appInfo: { name: "inline-message-results", version: "1.0.0" }, appCapabilities: { availableDisplayModes: ["inline"] }, protocolVersion: "2026-01-26",
    } }])
    expect(card.document.body.textContent).toContain("Loading Inline messages")
    card.notify("ui/notifications/tool-result", result())
    expect(card.document.querySelectorAll("li")).toHaveLength(0)
    card.receive({ jsonrpc: "2.0", id: 1, result: { protocolVersion: "2026-01-26", hostContext: { theme: "dark" } } })
    expect(card.sent.some((message) => message.method === "ui/notifications/initialized")).toBe(true)
    expect(card.document.documentElement.dataset.theme).toBe("dark")
    card.notify("ui/notifications/tool-result", result())
    expect(card.document.querySelector("h2")?.textContent).toBe("Launch")
    expect(card.document.querySelector("#root")?.getAttribute("aria-busy")).toBe("false")
  })

  it("shows compact context, filters and real names in the existing newest-first order without visible IDs", () => {
    const card = mount()
    card.notify("ui/notifications/tool-result", result({ query: "blocker", content: "documents", since: "1790726400", senderUserId: "4", nextOffsetId: "8",
      messages: [message({ id: "11", out: true, fromId: "1", media: { kind: "document", fileName: "Launch notes.pdf", url: "https://private.example/document" } }), message({ id: "10", senderDisplayName: "Morgan" })],
    }))
    expect(card.document.querySelectorAll("li")).toHaveLength(2)
    expect(Array.from(card.document.querySelectorAll(".attachment"), (node) => node.textContent)).toEqual(["Document · Launch notes.pdf"])
    expect(Array.from(card.document.querySelectorAll("strong"), (node) => node.textContent)).toEqual(["You", "Morgan"])
    expect(card.document.querySelector("header")?.textContent).toContain("Inline · 2 matches · Newest first")
    expect(card.document.querySelector("header")?.textContent).toContain("“blocker” · Documents · From Morgan · Since ")
    expect(card.document.body.textContent).not.toMatch(/Message \d|Chat \d|User \d| UTC/)
    expect(card.document.querySelector("footer")?.textContent).toContain("Older results may be available. Ask in chat to continue.")
    expect(card.document.querySelectorAll("img,a,iframe,video")).toHaveLength(0)
    expect(card.fetch).not.toHaveBeenCalled()
    expect(card.sent.every((message) => ["ui/initialize", "ui/notifications/initialized", "ui/notifications/size-changed"].includes(message.method))).toBe(true)
  })

  it("keeps sparse results independent with native avatars, names above bubbles, and dates inside", () => {
    const card = mount()
    card.notify("ui/notifications/tool-result", result({ query: "team", messages: [
      message({ senderDisplayName: "Dena Sohrabi" }), message({ id: "9", senderDisplayName: "Dena Sohrabi" }),
      message({ id: "8", out: true }),
    ] }))
    expect(card.document.querySelectorAll(".incoming .avatar")).toHaveLength(2)
    expect(card.document.querySelectorAll(".outgoing .avatar")).toHaveLength(0)
    expect(card.document.querySelectorAll(".bubble time")).toHaveLength(3)
    expect(card.document.querySelectorAll(".message-content > .sender")).toHaveLength(3)
    expect(card.document.querySelectorAll(".bubble .sender")).toHaveLength(0)
    expect(Array.from(card.document.querySelectorAll(".avatar-initial"), (node) => node.textContent)).toEqual(["D", "D"])
    expect(card.document.querySelector(".avatar")?.getAttribute("aria-hidden")).toBe("true")
    expect(card.document.querySelector(".outgoing .sender")?.textContent).toBe("You")
    expect(card.document.querySelector("ol")?.getAttribute("aria-label")).toBe("Returned messages, newest first")
  })

  it("uses one native grapheme initial and name-based colors with an honest unknown-person fallback", () => {
    const card = mount()
    card.notify("ui/notifications/tool-result", result({ messages: [
      message({ senderDisplayName: "@morgan" }), message({ id: "9", fromId: "88", senderDisplayName: "morgan" }),
      message({ id: "8", senderDisplayName: "👩🏽‍💻 Dev" }), message({ id: "7", senderDisplayName: "  " }),
    ] }))
    const rows = card.document.querySelectorAll("li")
    expect(rows[0]?.style.getPropertyValue("--avatar-base")).toBe(rows[1]?.style.getPropertyValue("--avatar-base"))
    expect(Array.from(card.document.querySelectorAll(".avatar-initial"), (node) => node.textContent)).toEqual(["M", "M", "👩🏽‍💻"])
    expect(rows[3]?.querySelector(".avatar-person")).not.toBeNull()
    expect(rows[3]?.querySelector(".avatar")?.textContent).toBe("")
  })

  it("uses only the author's signed photo from UI metadata and reveals its fallback on error", () => {
    const card = mount()
    const photoUrl = "https://api.inline.chat/file?id=avatar-fixture&exp=9999999999&sig=fixture"
    card.notify("ui/notifications/tool-result", { ...result({ messages: [message({ senderDisplayName: "Dena" })] }),
      _meta: { inline: { senderAvatarUrls: { "4": photoUrl, "88": photoUrl } } },
    })
    const photo = card.document.querySelector("img")!
    expect(card.document.querySelectorAll("img")).toHaveLength(1)
    expect(photo.src).toBe(photoUrl)
    expect(photo.alt).toBe("")
    expect(photo.referrerPolicy).toBe("no-referrer")
    expect([photo.width, photo.height]).toEqual([28, 28])
    expect(photo.parentElement?.querySelector(".avatar-initial")?.textContent).toBe("D")
    photo.dispatchEvent(new card.window.Event("error"))
    expect(photo.hidden).toBe(true)
    expect(card.fetch).not.toHaveBeenCalled()
    expect(card.document.querySelector("#root")?.textContent).not.toContain("sig=")
  })

  it.each([
    "https://evil.example/file?id=1&exp=2&sig=3", "http://api.inline.chat/file?id=1&exp=2&sig=3",
    "https://api.inline.chat/other?id=1&exp=2&sig=3", "https://api.inline.chat/file?id=1&exp=2",
    "https://user:password@api.inline.chat/file?id=1&exp=2&sig=3", "https://api.inline.chat/file?id=1&exp=2&sig=3#track",
    "data:image/png;base64,fixture", "https://api.inline.chat/file?id=1&exp=2&sig=" + "a".repeat(4096),
  ])("ignores disallowed profile photo URLs (%s)", (url) => {
    const card = mount()
    card.notify("ui/notifications/tool-result", { ...result(), _meta: { inline: { senderAvatarUrls: { "4": url } } } })
    expect(card.document.querySelector("img")).toBeNull()
    expect(card.document.querySelector(".avatar-person")).not.toBeNull()
    expect(card.document.querySelector("[role=alert]")).toBeNull()
  })

  it("accepts released results that omit optional sender and continuation fields", () => {
    const card = mount()
    const released = result({ query: "team" })
    delete (released.structuredContent as Record<string, unknown>).senderUserId
    delete (released.structuredContent as Record<string, unknown>).nextOffsetId
    card.notify("ui/notifications/tool-result", released)
    expect(card.document.querySelectorAll("li")).toHaveLength(1)
    expect(card.document.querySelector("[role=alert]")).toBeNull()
    expect(card.document.querySelector("footer")).toBeNull()
  })

  it("treats empty filtered pages with a cursor as an incomplete page", () => {
    const card = mount()
    card.notify("ui/notifications/tool-result", result({ messages: [], query: "blocked", nextOffsetId: "8" }))
    expect(card.document.querySelector("footer")?.textContent).toContain("No messages returned on this page")
    expect(card.document.querySelector("footer")?.textContent).toContain("Older results may be available. Ask in chat to continue.")
    expect(card.document.body.textContent).not.toContain("No messages matched")
    card.notify("ui/notifications/tool-result", result({ messages: [], content: "photos", nextOffsetId: "8" }))
    expect(card.document.querySelector("footer")?.textContent).toContain("Older results may be available. Ask in chat to continue.")
    card.notify("ui/notifications/tool-result", result({ messages: [], query: "blocked" }))
    expect(card.document.querySelector("footer")?.textContent).toContain("No messages matched these filters on this page")
    card.notify("ui/notifications/tool-result", result({ messages: [] }))
    expect(card.document.querySelector("footer")?.textContent).toContain("No recent messages returned")
  })

  it("uses supplied author names or a matching DM peer and keeps unknown authors separate", () => {
    const card = mount()
    const chat = { chatId: "7", title: "Morgan", kind: "dm", space: null, peer: { userId: "4", displayName: "Morgan Lee", username: "morgan" } }
    card.notify("ui/notifications/tool-result", result({ chat, messages: [message(), message({ id: "9", out: true, senderDisplayName: "My name" })] }))
    expect(Array.from(card.document.querySelectorAll(".sender"), (node) => node.textContent)).toEqual(["Morgan Lee", "You"])
    card.notify("ui/notifications/tool-result", result({ chat: { ...chat, peer: { ...chat.peer, displayName: null } } }))
    expect(card.document.querySelector(".sender")?.textContent).toBe("@morgan")
    card.notify("ui/notifications/tool-result", result({ messages: [message({ fromId: "77" }), message({ id: "9", fromId: "88", senderDisplayName: "  " })] }))
    expect(Array.from(card.document.querySelectorAll(".sender"), (node) => node.textContent)).toEqual(["Member", "Member"])
    expect(card.document.querySelectorAll("li")).toHaveLength(2)
    expect(card.document.querySelectorAll(".unknown-sender")).toHaveLength(2)
    expect(card.document.body.textContent).not.toMatch(/77|88/)
    card.notify("ui/notifications/tool-result", result({ chat, messages: [message({ fromId: "88" })] }))
    expect(card.document.querySelector(".sender")?.textContent).not.toContain("Morgan")
  })

  it("shows browser-local times with readable day context and omits missing or invalid dates", () => {
    const card = mount()
    const today = new Date()
    today.setHours(13, 5, 0, 0)
    const yesterday = new Date(today)
    yesterday.setDate(yesterday.getDate() - 1)
    const oldDate = new Date(today.getFullYear() - 1, 0, 2, 13, 5)
    const dateValue = (date: Date) => String(Math.floor(date.getTime() / 1000))
    card.notify("ui/notifications/tool-result", result({ messages: [
      message({ date: dateValue(today) }), message({ id: "9", date: dateValue(yesterday) }), message({ id: "8", date: dateValue(oldDate) }),
      message({ id: "7", date: null }), message({ id: "6", date: "invalid" }), message({ id: "5", date: "999999999999999999" }),
    ] }))
    const times = card.document.querySelectorAll("time")
    const localTime = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(today)
    expect(Array.from(times, (node) => node.textContent)).toEqual([
      `Today, ${localTime}`, `Yesterday, ${localTime}`,
      `${new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(oldDate)}, ${localTime}`,
    ])
    expect(times[0]?.getAttribute("datetime")).toBe(today.toISOString())
    expect(times[0]?.getAttribute("title")).toBe(new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "short" }).format(today))
    expect(card.document.body.textContent).not.toMatch(/UTC|Time unavailable|Invalid Date|999999999999999999/)
    expect(card.document.querySelector("footer")).toBeNull()
  })

  it("keeps active filter coverage without displaying unresolved sender or cursor IDs", () => {
    const card = mount()
    card.notify("ui/notifications/tool-result", result({ senderUserId: "77", content: "photos", messages: [] }))
    expect(card.document.querySelector("header")?.textContent).toContain("0 filtered messages")
    expect(card.document.querySelector(".filters")?.textContent).toBe("Photos · Selected sender")
    expect(card.document.body.textContent).not.toContain("77")
  })

  it("expands already-returned text locally with a keyboard-accessible button and resets expansion for every result", () => {
    const card = mount()
    const text = `Opening\n${"long message ".repeat(50)}`
    card.notify("ui/notifications/tool-result", result({ messages: [message({ text, snippet: "Opening…" })] }))
    const button = card.document.querySelector("button")!
    expect(button.textContent).toBe("Show more")
    expect(button.getAttribute("aria-expanded")).toBe("false")
    expect(card.document.getElementById(button.getAttribute("aria-controls")!)?.textContent).toBe("Opening…")
    button.focus()
    expect(card.document.activeElement).toBe(button)
    button.click()
    expect(card.document.querySelector(".message-text")?.textContent).toBe(text)
    expect(button.getAttribute("aria-expanded")).toBe("true")
    expect(button.textContent).toBe("Show less")
    button.click()
    expect(card.document.querySelector(".message-text")?.textContent).toBe("Opening…")
    button.click()
    card.notify("ui/notifications/tool-result", result({ messages: [message({ text, snippet: "Opening…" })] }))
    expect(card.document.querySelector(".message-text")?.textContent).toBe("Opening…")
    expect(card.document.querySelector("button")?.getAttribute("aria-expanded")).toBe("false")
    expect(card.fetch).not.toHaveBeenCalled()
    expect(card.sent.some((message) => message.method === "tools/call" || message.method === "resources/read")).toBe(false)
  })

  it("renders chat strings as text, including HTML-like content in a maximum-size valid page", () => {
    const card = mount()
    const hostile = '<img src="https://example.test/track" onerror="window.compromised=1"><script>alert(1)</script>'
    card.notify("ui/notifications/tool-result", result({
      chat: { chatId: "7", title: hostile, kind: "dm", space: null }, query: hostile,
      messages: Array.from({ length: 50 }, (_, index) => message({ id: String(100 - index), text: hostile + " 🧵".repeat(4000), senderDisplayName: hostile,
        media: { kind: "document", fileName: hostile },
      })),
    }))
    expect(card.document.querySelectorAll("li")).toHaveLength(50)
    expect(card.document.querySelector("h2")?.textContent).toBe(hostile)
    expect(card.document.querySelector("header")?.textContent).toContain("Direct message · 50 matches")
    expect(card.document.querySelectorAll("img,script,iframe,a")).toHaveLength(0)
    expect(card.document.querySelector(".message-text")?.textContent).toContain(hostile)
    expect(card.document.querySelector(".sender")?.textContent).toBe(hostile)
    expect(card.document.querySelector(".attachment")?.textContent).toBe(`Document · ${hostile}`)
    expect(card.fetch).not.toHaveBeenCalled()
  })

  it.each([null, { isError: true }, { structuredContent: {} }, result({ messages: [message({ chatId: "99" })] }), result({ content: 9 }), result({ messages: [message({ senderDisplayName: {} })] })])(
    "clears old successful rows when the next result is failed or malformed (%j)", (invalid) => {
      const card = mount()
      card.notify("ui/notifications/tool-result", result())
      expect(card.document.querySelectorAll("li")).toHaveLength(1)
      card.notify("ui/notifications/tool-result", invalid)
      expect(card.document.querySelectorAll("li")).toHaveLength(0)
      expect(card.document.querySelector("[role=alert]")).not.toBeNull()
      expect(card.document.body.textContent).not.toContain("Launch")
    },
  )

  it("clears prior results on input and cancellation, updates host theme and ignores untrusted senders", () => {
    const card = mount()
    card.notify("ui/notifications/tool-result", result(), {})
    expect(card.document.querySelectorAll("li")).toHaveLength(0)
    card.notify("ui/notifications/tool-result", result())
    card.notify("ui/notifications/tool-input", { arguments: { chatId: "99" } })
    expect(card.document.querySelectorAll("li")).toHaveLength(0)
    expect(card.document.body.textContent).toContain("Loading Inline messages")
    card.notify("ui/notifications/tool-result", result())
    card.notify("ui/notifications/tool-cancelled", { reason: "cancelled" })
    expect(card.document.querySelectorAll("li")).toHaveLength(0)
    expect(card.document.querySelector("[role=alert]")?.textContent).toContain("cancelled")
    card.notify("ui/notifications/host-context-changed", { theme: "dark" })
    expect(card.document.documentElement.dataset.theme).toBe("dark")
  })

  it("shows the requested older-page bound from the host input without changing tool results", () => {
    const card = mount()
    card.notify("ui/notifications/tool-input", { arguments: { chatId: "7", offsetId: "12" } })
    card.notify("ui/notifications/tool-result", result())
    expect(card.document.querySelector("header")?.textContent).toContain("1 older message")
    expect(card.document.body.textContent).not.toContain("message 12")
    card.notify("ui/notifications/tool-input", { arguments: { chatId: "7" } })
    card.notify("ui/notifications/tool-result", result())
    expect(card.document.querySelector("header")?.textContent).toContain("1 recent message")
  })

  it("shows initialization errors and disposes its bridge on host teardown", () => {
    const card = mount(false)
    card.receive({ jsonrpc: "2.0", id: 1, error: { code: -1, message: "failure" } })
    expect(card.document.querySelector("[role=alert]")?.textContent).toContain("could not connect")
    const ready = mount()
    ready.notify("ui/notifications/tool-result", result())
    ready.receive({ jsonrpc: "2.0", id: 9, method: "ui/resource-teardown", params: { reason: "done" } })
    expect(ready.sent.at(-1)).toEqual({ jsonrpc: "2.0", id: 9, result: {} })
    ready.notify("ui/notifications/tool-result", result())
    expect(ready.document.querySelector("#root")?.childElementCount).toBe(0)
  })

  it("surfaces an unavailable host bridge after the initialization deadline", () => {
    const card = mount(false)
    const [timeout, delay] = card.timeouts.mock.calls[0]!
    expect(delay).toBe(10_000)
    expect(typeof timeout).toBe("function")
    ;(timeout as () => void)()
    expect(card.document.querySelector("[role=alert]")?.textContent).toContain("could not connect")
  })
})

it("registers a self-contained resource allowing only Inline profile photo resources", async () => {
  const registerResource = vi.fn()
  registerMessageResultsUi({ registerResource } as unknown as McpServer)
  expect(registerResource).toHaveBeenCalledOnce()
  const [name, uri, metadata, read] = registerResource.mock.calls[0]!
  expect(name).toBe("inline-message-results")
  expect(uri).toBe(MESSAGE_RESULTS_RESOURCE_URI)
  expect(metadata.mimeType).toBe(MESSAGE_RESULTS_MIME_TYPE)
  const resource = (await read()).contents[0]
  expect(resource.uri).toBe(uri)
  expect(resource.mimeType).toBe("text/html;profile=mcp-app")
  expect(resource.text).toBe(createMessageResultsHtml())
  expect(resource._meta.ui).toEqual({ prefersBorder: true, domain: "https://mcp.inline.chat", csp: { connectDomains: [], resourceDomains: ["https://api.inline.chat"], frameDomains: [] } })
  expect(resource.text).not.toMatch(/\bsrc=|\bhref=|\bfetch\(|\bXMLHttpRequest\b|\bWebSocket\b/)
})
