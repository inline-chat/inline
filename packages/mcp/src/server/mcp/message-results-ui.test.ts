import { afterEach, describe, expect, it, vi } from "vitest"
import { Window, type Element, type HTMLElement, type HTMLImageElement, type HTMLButtonElement } from "happy-dom"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { createMessageResultsHtml, LEGACY_MESSAGE_RESULTS_RESOURCE_URI, MESSAGE_RESULTS_MIME_TYPE, MESSAGE_RESULTS_RESOURCE_URI, registerMessageResultsUi } from "./message-results-ui"

const windows: Window[] = []
afterEach(async () => { await Promise.all(windows.splice(0).map((window) => window.happyDOM.close())); vi.restoreAllMocks() })
const chat = (chatId = "7", extra: Record<string, unknown> = {}) => ({ chatId, status: "available", chat: { chatId, title: chatId === "7" ? "Launch" : "Design", kind: "space_chat", space: { name: "Inline" }, unreadCount: 3, readMaxId: "9", lastMessagePreview: "Ready to ship", ...extra } })
const message = (extra: Record<string, unknown> = {}) => ({ id: "10", chatId: "7", text: "Hello team", out: false, fromId: "4", senderDisplayName: "Dena", date: "1790726400", media: null, ...extra })
const item = (extra: Record<string, unknown> = {}) => { const m = message(extra); return { chatId: m.chatId, messageId: m.id, status: "available", message: m } }
const page = (extra: Record<string, unknown> = {}) => ({ kind: "selected", nextOffsetId: null, nextAfterId: null, anchorMessageId: null, firstUnreadMessageId: null, note: null, ...extra })
const result = (extra: Record<string, unknown> = {}, metadata: Record<string, unknown> = {}) => ({ structuredContent: { presentation: "sources", chats: [chat(), chat("8")], items: [item()], activeChatId: null, page: page(), ...extra }, _meta: { inline: metadata } })
const catchUp = (extra: Record<string, unknown> = {}, metadata: Record<string, unknown> = {}) => result({ presentation: "catch_up", activeChatId: "7", page: page({ kind: "latest" }), ...extra }, metadata)
const signed = (file = "photo") => `https://api.inline.chat/file?id=${file}&exp=2050000000&sig=signed`
const signedR2 = (fileUniqueId = "INDabcdef", options: { host?: string; date?: string; expires?: string; signature?: string } = {}) => {
  const date = options.date ?? new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z")
  const url = new URL(`https://${options.host ?? `${"a".repeat(32)}.r2.cloudflarestorage.com`}/inline-prod/files/${fileUniqueId}/notes.pdf`)
  for (const [key, value] of Object.entries({ "X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": `testkey/${date.slice(0, 8)}/auto/s3/aws4_request`, "X-Amz-Date": date, "X-Amz-Expires": options.expires ?? "3600", "X-Amz-SignedHeaders": "host", "X-Amz-Signature": options.signature ?? "f".repeat(64) })) url.searchParams.set(key, value)
  return url.href
}
const flush = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve() }
function mount(options: { initialize?: boolean; capabilities?: Record<string, unknown>; context?: Record<string, unknown> } = {}) {
  const window = new Window({ url: "https://mcp.inline.chat", settings: { enableJavaScriptEvaluation: true } }); windows.push(window)
  const sent: Array<Record<string, any>> = [], parent = { postMessage: vi.fn((data: Record<string, any>) => sent.push(data)) }
  Object.defineProperty(window, "parent", { value: parent })
  const html = createMessageResultsHtml(), script = html.match(/<script>([\s\S]+)<\/script>/)![1]!
  window.document.write(html.replace(/<script>[\s\S]+<\/script>/, ""))
  const fetch = vi.fn(() => { throw new Error("No direct data requests") }); Object.defineProperty(window, "fetch", { value: fetch })
  const timeouts = vi.spyOn(window, "setTimeout"); window.eval(script)
  const receive = (data: unknown, source: unknown = parent) => window.dispatchEvent(new window.MessageEvent("message", { source: source as any, data }))
  const notify = (method: string, params: unknown, source: unknown = parent) => receive({ jsonrpc: "2.0", method, params }, source)
  const deliver = (data: unknown) => { notify("ui/notifications/tool-input", { arguments: {} }); notify("ui/notifications/tool-result", data) }
  const query = <T extends Element = HTMLElement>(selector: string) => window.document.querySelector<T>(selector)!
  const click = (selector: string) => query<any>(selector).click()
  const lastCall = (method = "tools/call") => sent.filter((value) => value.method === method).at(-1)!
  const reply = async (call: Record<string, any>, value: unknown) => { receive({ jsonrpc: "2.0", id: call.id, result: value }); await flush() }
  if (options.initialize !== false) receive({ jsonrpc: "2.0", id: 1, result: { protocolVersion: "2026-01-26", hostCapabilities: options.capabilities ?? { serverTools: {}, openLinks: {} }, hostContext: { theme: "light", displayMode: "inline", availableDisplayModes: ["inline", "fullscreen"], ...options.context } } })
  const expand = async () => { click(".expand-reader"); await reply(lastCall("ui/request-display-mode"), { mode: "fullscreen" }) }
  return { window, document: window.document, sent, parent, receive, notify, deliver, query, click, lastCall, reply, expand, fetch, timeouts }
}

describe("Inline sources", () => {
  it("initializes the documented bridge before accepting data and ignores untrusted senders", () => {
    const card = mount({ initialize: false })
    expect(card.sent[0]).toEqual({ jsonrpc: "2.0", id: 1, method: "ui/initialize", params: { appInfo: { name: "inline-message-results", version: "2.0.0" }, appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }, protocolVersion: "2026-01-26" } })
    card.notify("ui/notifications/tool-result", result()); expect(card.document.querySelector(".source")).toBeNull()
    card.receive({ jsonrpc: "2.0", id: 1, result: { protocolVersion: "2026-01-26", hostContext: { theme: "dark" } } })
    card.notify("ui/notifications/tool-result", result(), {}); expect(card.document.querySelector(".source")).toBeNull()
    card.notify("ui/notifications/tool-result", result()); expect(card.query(".source-chat").textContent).toBe("Launch")
    expect(card.document.documentElement.dataset.theme).toBe("dark"); expect(card.fetch).not.toHaveBeenCalled()
  })
  it("preserves cross-chat selection order and every source's chat/space/author/time", () => {
    const card = mount(); card.deliver(result({ items: [item({ chatId: "8", id: "20", text: "Original deadline" }), item({ id: "11", out: true, text: "New deadline" }), item({ id: "12", fromId: null, senderDisplayName: "" })] }))
    expect(Array.from(card.document.querySelectorAll(".source"), (el) => (el as HTMLElement).dataset.chatId)).toEqual(["8", "7", "7"])
    expect(Array.from(card.document.querySelectorAll(".source .sender"), (el) => el.textContent)).toEqual(["Dena", "You", "Member"])
    expect(card.document.querySelectorAll(".source time")).toHaveLength(3)
    expect(card.document.querySelector(".chat-list,.history,.outgoing")).toBeNull()
    expect(card.query(".source-list").getAttribute("aria-label")).toContain("requested order")
  })
  it("limits compact selection to five, negotiates fullscreen for the rest, and handles host refusal", async () => {
    const card = mount(); card.deliver(result({ items: Array.from({ length: 20 }, (_, i) => item({ id: String(i + 1) })) }))
    expect(card.document.querySelectorAll(".source")).toHaveLength(5)
    card.click(".show-all-sources"); await card.reply(card.lastCall("ui/request-display-mode"), { mode: "inline" })
    expect(card.document.querySelectorAll(".source")).toHaveLength(20)
    expect(card.document.body.textContent).toContain("Expanded view isn’t available here")
    card.click(".show-all-sources"); expect(card.document.querySelectorAll(".source")).toHaveLength(5)
    card.click(".show-all-sources"); await card.reply(card.lastCall("ui/request-display-mode"), { mode: "fullscreen" })
    expect(card.document.querySelectorAll(".source")).toHaveLength(20); expect(card.document.querySelector(".chat-list")).toBeNull()
    const fallback = mount({ context: { availableDisplayModes: ["inline"] } }); fallback.deliver(result({ items: Array.from({ length: 6 }, (_, i) => item({ id: String(i + 1) })) })); fallback.click(".show-all-sources")
    expect(fallback.document.querySelectorAll(".source")).toHaveLength(6); expect(fallback.sent.some((v) => v.method === "ui/request-display-mode")).toBe(false)
  })
  it("uses original rich-text offsets, preserves nested styles and rejects dangerous links/invalid surrogate ranges", () => {
    const card = mount(); const text = "First\n\nsecond third 👩🏽‍💻"
    card.deliver(result({ items: [item({ text, snippet: "First second third", entities: [{ type: 3, offset: 7, length: 6, url: "https://inline.chat" }, { type: 5, offset: 7, length: 12 }, { type: 6, offset: 14, length: 5 }, { type: 3, offset: 0, length: 5, url: "javascript:alert(1)" }, { type: 5, offset: 21, length: 1 }] })] }))
    expect(card.query(".message-text a").textContent).toBe("second"); expect(card.query(".message-text em").textContent).toBe("third")
    expect(card.query(".message-text").textContent).toBe(text); expect(card.document.querySelectorAll("a")).toHaveLength(1)
    card.click("a"); expect(card.lastCall("ui/open-link").params).toEqual({ url: "https://inline.chat/" })
  })
  it("expands long canonical text locally and exposes truncation rather than promising the complete original", () => {
    const card = mount(); const text = "line\n".repeat(200); card.deliver(result({ items: [item({ text, snippet: "normalized", textTruncated: true })] }))
    expect(card.query(".message-text").textContent).not.toBe("normalized"); expect(card.query(".message-text").textContent!.length).toBeLessThan(300)
    card.click(".expand-text"); expect(card.query(".message-text").textContent).toBe(text); expect(card.query(".expand-text").getAttribute("aria-expanded")).toBe("true")
    expect(card.document.body.textContent).toContain("Message text is truncated")
    expect(card.sent.some((v) => v.method === "tools/call")).toBe(false)
  })
  it("uses only signed UI metadata for modest photos, full-size click, document opening and unavailable fallback", async () => {
    const card = mount(); card.deliver(result({ items: [item({ media: { kind: "photo", url: "https://evil.test/file", width: 400, height: 300 } }), item({ id: "11", media: { kind: "document", fileName: "Notes.pdf", mimeType: "application/pdf", sizeBytes: 1500, url: signed("untrusted") } }), item({ id: "12", media: { kind: "voice", durationSeconds: 61 } })] }, { messageMedia: { "7:10": { thumbnailUrl: signed("thumb"), originalUrl: signed("original") }, "7:11": { originalUrl: signed("pdf") } } }))
    const thumb = card.query<HTMLImageElement>(".photo-frame img"); expect(thumb.src).toBe(signed("thumb")); expect(thumb.referrerPolicy).toBe("no-referrer"); expect(thumb.loading).toBe("lazy")
    expect(card.document.querySelector('[src*="original"]')).toBeNull(); card.click(".photo-open")
    expect(card.query<HTMLImageElement>(".media-viewer img").src).toBe(signed("original")); expect(card.document.activeElement?.className).toBe("close-media")
    card.window.dispatchEvent(new card.window.KeyboardEvent("keydown", { key: "Escape" })); expect(card.document.querySelector(".media-viewer")).toBeNull()
    expect(card.document.activeElement?.className).toBe("photo-open"); card.click(".media-open"); expect(card.lastCall("ui/open-link").params.url).toBe(signed("pdf"))
    expect(card.query(".file-meta").textContent).toContain("PDF · 1.5 KB"); expect(card.document.body.textContent).toContain("1:01")
    thumb.dispatchEvent(new card.window.Event("error")); expect(card.document.body.textContent).toContain("Preview unavailable")
    const call = card.lastCall("ui/open-link"); card.receive({ jsonrpc: "2.0", id: call.id, error: { code: -1 } }); await flush(); expect(card.document.body.textContent).toContain("Could not open")
  })
  it.each(["https://evil.test/file?id=a&exp=b&sig=c", "https://api.inline.chat/file?id=x", "https://api.inline.chat/file?id=x&exp=y&sig=z#fragment", "https://me@api.inline.chat/file?id=x&exp=y&sig=z", "data:image/png;base64,a", "javascript:alert(1)"])("rejects untrusted media URL %s", (url) => {
    const card = mount(); card.deliver(result({ items: [item({ media: { kind: "photo", url: signed() } })] }, { messageMedia: { "7:10": { thumbnailUrl: url, originalUrl: url } } }))
    expect(card.document.querySelector("img,.media-open,.photo-open")).toBeNull(); expect(card.document.body.textContent).toContain("Attachment unavailable")
  })
  it("opens canonical signed R2 originals only through the host and never embeds them", () => {
    const card = mount(), original = signedR2()
    card.deliver(result({ items: [item({ media: { kind: "document", fileName: "Notes.pdf", sizeBytes: 50 } })] }, { messageMedia: { "7:10": { thumbnailUrl: original, originalUrl: original, originalFileUniqueId: "INDabcdef" } } }))
    expect(card.document.querySelector("img,iframe,video")).toBeNull(); card.click(".media-open"); expect(card.lastCall("ui/open-link").params.url).toBe(original)
  })
  it.each([
    { url: signedR2("INDother"), uniqueId: "INDabcdef" },
    { url: signedR2("INDabcdef", { host: "evil.test" }), uniqueId: "INDabcdef" },
    { url: signedR2("INDabcdef", { signature: "fake" }), uniqueId: "INDabcdef" },
    { url: signedR2("INDabcdef", { date: "20200101T000000Z" }), uniqueId: "INDabcdef" },
    { url: signedR2("INDabcdef", { expires: "604801" }), uniqueId: "INDabcdef" },
    { url: signedR2("INDabcdef", { date: new Date(Date.now() + 60 * 60 * 1000).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z") }), uniqueId: "INDabcdef" },
    { url: signedR2(), uniqueId: null },
  ])("rejects noncanonical or expired R2 capabilities %j", ({ url, uniqueId }) => {
    const card = mount(); card.deliver(result({ items: [item({ media: { kind: "document" } })] }, { messageMedia: { "7:10": { originalUrl: url, originalFileUniqueId: uniqueId } } }))
    expect(card.document.querySelector(".media-open,img")).toBeNull(); expect(card.document.body.textContent).toContain("Attachment unavailable")
  })
  it("keeps unavailable originals visible and renders hostile data only as text", () => {
    const card = mount(); const hostile = '<img src="https://evil.test" onerror="alert(1)"><script>bad</script>'
    card.deliver(result({ chats: [chat("7", { title: hostile })], items: [item({ text: hostile, senderDisplayName: hostile, media: { kind: "document", fileName: hostile } }), { chatId: "7", messageId: "11", status: "unavailable", message: null }] }))
    expect(card.document.querySelectorAll("img,iframe,script")).toHaveLength(0); expect(card.document.querySelectorAll(".source")).toHaveLength(2)
    expect(card.query(".source-chat").textContent).toBe(hostile); expect(card.document.body.textContent).toContain("no longer have access")
  })
  it("retains old published v1 payload support as selected source evidence", () => {
    const card = mount(); card.deliver({ structuredContent: { chat: chat().chat, messages: [message()], content: "all", nextOffsetId: "9", since: null, until: null } })
    expect(card.query(".source-chat").textContent).toBe("Launch"); expect(card.document.querySelector(".load-older")).toBeNull()
  })
})

describe("Inline catch-up reader", () => {
  it("starts compact, previews latest rows, and expands only after a supported host mode response", async () => {
    const card = mount(); card.deliver(catchUp({ items: Array.from({ length: 6 }, (_, i) => item({ id: String(i + 1), text: `row ${i + 1}` })) }))
    expect(Array.from(card.document.querySelectorAll(".source"), (el) => (el as HTMLElement).dataset.messageId)).toEqual(["4", "5", "6"])
    expect(card.document.querySelector(".history")).toBeNull(); card.click(".expand-reader"); expect(card.document.querySelector(".history")).toBeNull()
    await card.reply(card.lastCall("ui/request-display-mode"), { mode: "fullscreen" }); expect(card.document.querySelectorAll(".history .message")).toHaveLength(6)
    expect(card.document.querySelector("textarea,input,form")).toBeNull(); expect(card.query(".chat-item.active").getAttribute("aria-current")).toBe("true")
    expect(card.query(".unread-badge").getAttribute("aria-label")).toBe("3 unread messages")
    const unsupported = mount({ context: { availableDisplayModes: ["inline"] }, capabilities: {} }); unsupported.deliver(catchUp())
    expect(unsupported.document.querySelector(".expand-reader,.show-context")).toBeNull()
  })
  it("keeps a useful catch-up preview and announces when the host declines expansion", async () => {
    const card = mount(); card.deliver(catchUp()); card.click(".expand-reader")
    await card.reply(card.lastCall("ui/request-display-mode"), { mode: "inline" })
    expect(card.document.querySelector(".history")).toBeNull(); expect(card.document.querySelector(".source")).not.toBeNull()
    expect(card.query('[role="status"]').textContent).toBe("Expanded view isn’t available here.")
  })
  it("renders chronological sender groups, date boundaries, honest read boundary and service events", async () => {
    const card = mount(); card.deliver(catchUp({ page: page({ kind: "unread", note: "Exact first-unread location is unavailable." }), items: [item({ id: "10" }), item({ id: "11", date: "1790726450" }), item({ id: "12", out: true }), item({ id: "13", date: "1790812800" }), item({ id: "14", text: "", date: "1790812850", serviceMessage: { kind: "pinned_message", messageId: "10" } })] })); await card.expand()
    expect(Array.from(card.document.querySelectorAll(".history .message"), (el) => (el as HTMLElement).dataset.messageId)).toEqual(["10", "11", "12", "13", "14"])
    expect(card.document.querySelectorAll(".grouped")).toHaveLength(1); expect(card.document.querySelectorAll(".date-separator")).toHaveLength(2)
    expect(card.query(".read-boundary-separator").textContent).toBe("Since last read"); expect(card.document.querySelector(".unread-separator")).toBeNull()
    expect(card.query(".service-message").textContent).toContain("Pinned a message"); expect(card.query(".service-message").textContent).not.toContain("Empty message")
    card.click(".load-unread"); expect(card.lastCall().params.arguments.startAt).toBe("unread"); expect(card.query<HTMLButtonElement>(".load-latest").disabled).toBe(true)
  })
  it("jumps to loaded reply targets locally and fetches authorized context for unloaded targets", async () => {
    const card = mount(); card.deliver(catchUp({ items: [item(), item({ id: "11", replyToMsgId: "10", replyToMessage: { id: "10", text: "Hello team", fromId: "4", out: false, senderDisplayName: "Dena" } }), item({ id: "12", replyToMsgId: "3" })] })); await card.expand()
    card.click('.message[data-message-id="11"] .reply-jump'); expect(card.query('.message[data-message-id="10"]').classList.contains("highlighted")).toBe(true)
    expect(card.sent.some((v) => v.method === "tools/call")).toBe(false)
    card.click('.message[data-message-id="12"] .reply-jump'); expect(card.lastCall().params.arguments).toEqual({ presentation: "catch_up", chatIds: ["7", "8"], activeChatId: "7", anchorMessageId: "3" })
  })
  it("fetches real source context without redefining model analysis or emitting messages", async () => {
    const card = mount(); card.deliver(result()); card.click(".show-context"); await card.reply(card.lastCall("ui/request-display-mode"), { mode: "fullscreen" })
    expect(card.lastCall().params.arguments.anchorMessageId).toBe("10"); await card.reply(card.lastCall(), catchUp({ page: page({ kind: "context", anchorMessageId: "10" }) }))
    expect(card.document.querySelector(".history")).not.toBeNull()
    expect(card.sent.some((v) => ["ui/message", "ui/update-model-context"].includes(v.method))).toBe(false)
  })
  it("preserves per-chat position and mobile back navigation, fencing late chat responses", async () => {
    const card = mount(); card.deliver(catchUp()); await card.expand()
    const history = card.query<HTMLElement>(".history"); history.scrollTop = 80; history.dispatchEvent(new card.window.Event("scroll"))
    card.click('.chat-item[data-chat-id="8"]'); const obsolete = card.lastCall(); expect(card.document.querySelector(".history .message")).toBeNull()
    card.click('.chat-item[data-chat-id="7"]'); expect(card.query<HTMLElement>(".history").scrollTop).toBe(80)
    await card.reply(obsolete, catchUp({ activeChatId: "8", items: [item({ chatId: "8", text: "Stale response" })] }))
    expect(card.query(".reader-title").textContent).toContain("Launch"); expect(card.document.body.textContent).not.toContain("Stale response")
    card.click(".back-to-chats"); expect(card.query<HTMLElement>("#root").dataset.pane).toBe("list")
    card.click('.chat-item[data-chat-id="7"]'); expect(card.query<HTMLElement>("#root").dataset.pane).toBe("chat")
    card.notify("ui/notifications/host-context-changed", { theme: "dark", safeAreaInsets: { bottom: 24 } }); expect(card.query<HTMLElement>("#root").style.getPropertyValue("--safe-bottom")).toBe("24px")
  })
  it("preserves visible row when prepending or appending history and retains both cursors", async () => {
    const card = mount(); card.deliver(catchUp({ items: [item({ id: "10" }), item({ id: "11" })], page: page({ kind: "unread", nextOffsetId: "10", nextAfterId: "11" }) })); await card.expand()
    vi.spyOn(card.window.HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      const h = (this.closest(".history") as HTMLElement | null); const i = h ? Array.from(h.querySelectorAll(".message")).indexOf(this) : -1
      const top = this.classList.contains("history") ? 100 : i >= 0 ? 100 + i * 30 - h!.scrollTop : 0
      return new card.window.DOMRect(0, top, 300, 30)
    })
    card.query<HTMLElement>(".history").scrollTop = 30; card.query(".history").dispatchEvent(new card.window.Event("scroll"))
    card.click(".load-older"); await card.reply(card.lastCall(), catchUp({ items: [item({ id: "8" }), item({ id: "9" })], page: page({ kind: "older", nextOffsetId: "8" }) }))
    expect(card.query<HTMLElement>(".history").scrollTop).toBe(90)
    card.click(".load-newer"); expect(card.lastCall().params.arguments.afterId).toBe("11"); await card.reply(card.lastCall(), catchUp({ items: [item({ id: "12" })], page: page({ kind: "newer", nextAfterId: "12" }) }))
    expect(card.query<HTMLElement>(".history").scrollTop).toBe(90); expect(card.document.querySelectorAll(".history .message")).toHaveLength(5)
    card.click(".load-older"); expect(card.lastCall().params.arguments.offsetId).toBe("8")
  })
  it("merges app-originated pages despite permitted host input/result echoes", async () => {
    const card = mount(); card.deliver(catchUp({ page: page({ kind: "latest", nextOffsetId: "10" }) })); await card.expand()
    card.click(".load-older"); const call = card.lastCall(), older = catchUp({ items: [item({ id: "9" })], page: page({ kind: "older", nextOffsetId: "9" }) })
    card.notify("ui/notifications/tool-input-partial", { arguments: { presentation: "catch_up" } })
    card.notify("ui/notifications/tool-input", { arguments: call.params.arguments })
    card.notify("ui/notifications/tool-result", older)
    await card.reply(call, older)
    expect(Array.from(card.document.querySelectorAll(".history .message"), (el) => (el as HTMLElement).dataset.messageId)).toEqual(["9", "10"])
    // Hosts may deliver the correlated response before the input/result echoes.
    card.click(".load-older"); const second = card.lastCall(), next = catchUp({ items: [item({ id: "8" })], page: page({ kind: "older", nextOffsetId: "8" }) })
    await card.reply(second, next)
    card.notify("ui/notifications/tool-input", { arguments: second.params.arguments }); card.notify("ui/notifications/tool-result", next)
    expect(Array.from(card.document.querySelectorAll(".history .message"), (el) => (el as HTMLElement).dataset.messageId)).toEqual(["8", "9", "10"])
    card.deliver(result({ items: [item({ text: "New model result" })] }))
    expect(card.document.body.textContent).toContain("New model result")
  })
  it("accepts a new model refresh with the same arguments as a completed app call", async () => {
    const card = mount(); card.deliver(catchUp()); await card.expand()
    card.click(".load-latest"); const call = card.lastCall()
    await card.reply(call, catchUp({ items: [item({ text: "App refreshed" })] }))
    card.notify("ui/notifications/tool-input", { arguments: call.params.arguments })
    card.notify("ui/notifications/tool-result", catchUp({ items: [item({ text: "New model refresh" })] }))
    await vi.waitFor(() => expect(card.document.body.textContent).toContain("New model refresh"))
    expect(card.document.body.textContent).not.toContain("App refreshed")
  })
  it("accepts a same-argument model refresh that arrives while an app call is pending", async () => {
    const card = mount(); card.deliver(catchUp()); await card.expand()
    card.click(".load-latest"); const call = card.lastCall()
    card.notify("ui/notifications/tool-input", { arguments: call.params.arguments })
    card.notify("ui/notifications/tool-result", catchUp({ items: [item({ text: "New model refresh" })] }))
    await card.reply(call, catchUp({ items: [item({ text: "Older app refresh" })] }))
    await vi.waitFor(() => expect(card.document.body.textContent).toContain("New model refresh"))
    expect(card.document.body.textContent).not.toContain("Older app refresh")
  })
  it("accepts a same-argument model refresh when the pending app request times out", async () => {
    const card = mount(); card.deliver(catchUp()); await card.expand()
    card.click(".load-latest"); const call = card.lastCall()
    card.notify("ui/notifications/tool-input", { arguments: call.params.arguments })
    card.notify("ui/notifications/tool-result", catchUp({ items: [item({ text: "Successful model refresh" })] }))
    const [timeout] = [...card.timeouts.mock.calls].reverse().find(([, delay]) => delay === 15_000)!
    ;(timeout as () => void)()
    await vi.waitFor(() => expect(card.document.body.textContent).toContain("Successful model refresh"))
  })
  it("fences a deferred same-argument result after an explicit authorization denial", async () => {
    const card = mount(); card.deliver(catchUp()); await card.expand()
    const digests = vi.spyOn(card.window.crypto.subtle, "digest")
    card.click(".load-latest"); const call = card.lastCall()
    card.notify("ui/notifications/tool-input", { arguments: call.params.arguments })
    card.notify("ui/notifications/tool-result", catchUp({ items: [item({ text: "Private deferred result" })] }))
    card.receive({ jsonrpc: "2.0", id: call.id, error: { code: 401, message: "Authorization denied" } })
    await Promise.all(digests.mock.results.map((entry) => entry.value)); await flush()
    expect(card.document.body.textContent).not.toContain("Private deferred result")
    expect(card.document.querySelector(".history .message")).toBeNull()
  })
  it("ignores a completed app echo arriving after a newer outer result", async () => {
    const card = mount(); card.deliver(catchUp({ page: page({ kind: "latest", nextOffsetId: "10" }) })); await card.expand()
    const digests = vi.spyOn(card.window.crypto.subtle, "digest")
    card.click(".load-older"); const call = card.lastCall(), older = catchUp({ items: [item({ id: "9", text: "Older app page" })], page: page({ kind: "older" }) })
    await card.reply(call, older)
    card.deliver(result({ items: [item({ text: "New model evidence" })] }))
    card.notify("ui/notifications/tool-input", { arguments: call.params.arguments }); card.notify("ui/notifications/tool-result", older)
    await Promise.all(digests.mock.results.map((entry) => entry.value)); await flush()
    expect(card.document.body.textContent).toContain("New model evidence")
    expect(card.document.body.textContent).not.toContain("Older app page")
  })
  it("bounds history to 300 rows and restores the trimmed edge through a genuine opposite cursor", async () => {
    const card = mount(); const rows = (start: number) => Array.from({ length: 50 }, (_, i) => item({ id: String(start + i) }))
    card.deliver(catchUp({ items: rows(351), page: page({ kind: "latest", nextOffsetId: "351" }) })); await card.expand()
    for (const start of [301, 251, 201, 151, 101, 51]) { card.click(".load-older"); await card.reply(card.lastCall(), catchUp({ items: rows(start), page: page({ kind: "older", nextOffsetId: String(start) }) })) }
    expect(card.document.querySelectorAll(".history .message")).toHaveLength(300)
    expect(card.query<HTMLElement>(".history .message").dataset.messageId).toBe("51")
    card.click(".load-newer"); expect(card.lastCall().params.arguments.afterId).toBe("350")
    await card.reply(card.lastCall(), catchUp({ items: rows(351), page: page({ kind: "newer" }) }))
    expect(card.document.querySelectorAll(".history .message")).toHaveLength(300); card.click(".load-older"); expect(card.lastCall().params.arguments.offsetId).toBe("101")
  })
  it("clears cached rows and signed media on an authoritative denial while paging", async () => {
    const card = mount(); card.deliver(catchUp({ items: [item({ media: { kind: "photo" } })], page: page({ kind: "latest", nextOffsetId: "10" }) }, { messageMedia: { "7:10": { thumbnailUrl: signed(), originalUrl: signed() } } })); await card.expand()
    card.click(".load-older"); await card.reply(card.lastCall(), catchUp({ chats: [{ chatId: "7", status: "unavailable", chat: null }, chat("8")], items: [], page: page({ kind: "older" }) }))
    expect(card.document.querySelector(".history .message,img")).toBeNull(); expect(card.document.body.textContent).toContain("no longer have access")
    expect(card.document.querySelector('button.chat-item[data-chat-id="7"]')).toBeNull()
  })
  it.each([401, 403])("clears cached conversations and signed media for an explicit RPC authorization error %s", async (code) => {
    const card = mount(); card.deliver(catchUp({ items: [item({ media: { kind: "photo" } })], page: page({ kind: "latest", nextOffsetId: "10" }) }, { messageMedia: { "7:10": { thumbnailUrl: signed(), originalUrl: signed() } } })); await card.expand()
    card.click(".load-older"); card.receive({ jsonrpc: "2.0", id: card.lastCall().id, error: { code, message: "Authorization denied" } }); await flush()
    expect(card.document.querySelector(".history .message,img")).toBeNull()
    expect(card.document.querySelector("button.chat-item")).toBeNull()
    expect(card.document.body.textContent).not.toContain("Launch")
  })
  it("retains a loaded page when the bridge times out without an authorization denial", async () => {
    const card = mount(); card.deliver(catchUp({ page: page({ kind: "latest", nextOffsetId: "10" }) })); await card.expand()
    card.click(".load-older")
    const [timeout] = [...card.timeouts.mock.calls].reverse().find(([, delay]) => delay === 15_000)!
    ;(timeout as () => void)(); await flush()
    expect(card.document.querySelector(".history .message")).not.toBeNull()
    expect(card.document.body.textContent).toContain("Hello team")
    expect(card.document.body.textContent).toContain("Could not load")
  })
  it("fences old app calls and duplicate host results after a new outer input; clears malformed results", async () => {
    const card = mount(); card.deliver(catchUp()); await card.expand(); card.click(".load-latest"); const old = card.lastCall()
    card.deliver(result({ items: [item({ text: "New evidence" })] })); await card.reply(old, catchUp({ items: [item({ text: "Old private rows" })] }))
    card.notify("ui/notifications/tool-result", catchUp()); expect(card.document.body.textContent).toContain("New evidence"); expect(card.document.body.textContent).not.toContain("Old private rows")
    card.deliver(result({ items: [item({ chatId: "99" })] })); expect(card.document.querySelector(".source,.history")).toBeNull(); expect(card.document.querySelector("[role=alert]")).not.toBeNull()
  })
  it("rejects an old outer result when complete new arguments select different sources", () => {
    const card = mount(); card.deliver(result())
    card.notify("ui/notifications/tool-input", { arguments: { presentation: "sources", items: [{ chatId: "8", messageId: "20" }] } })
    card.notify("ui/notifications/tool-result", result())
    expect(card.document.querySelector(".source")).toBeNull()
    card.notify("ui/notifications/tool-result", result({ items: [item({ chatId: "8", id: "20", text: "Current source" })] }))
    expect(card.document.body.textContent).toContain("Current source")
  })
  it("uses the first available default chat and rejects stale same-chat window notifications", () => {
    const card = mount(), chats = [{ chatId: "7", status: "unavailable", chat: null }, chat("8")]
    card.notify("ui/notifications/tool-input", { arguments: { presentation: "catch_up", chatIds: ["7", "8"], startAt: "latest" } })
    card.notify("ui/notifications/tool-result", catchUp({ chats, activeChatId: "8", items: [item({ chatId: "8" })] }))
    expect(card.document.querySelector(".source")).not.toBeNull()
    card.notify("ui/notifications/tool-input", { arguments: { presentation: "catch_up", chatIds: ["7", "8"], activeChatId: "8", anchorMessageId: "3" } })
    card.notify("ui/notifications/tool-result", catchUp({ chats, activeChatId: "8", items: [item({ chatId: "8" })] }))
    expect(card.document.querySelector(".source")).toBeNull()
    card.notify("ui/notifications/tool-result", catchUp({ chats, activeChatId: "8", items: [item({ id: "3", chatId: "8" })], page: page({ kind: "context", anchorMessageId: "3" }) }))
    expect(card.document.querySelector(".source")).not.toBeNull()
  })
  it("surfaces initialization deadline/cancellation and tears down pending bridge requests", async () => {
    const noHost = mount({ initialize: false }); const [timeout, delay] = noHost.timeouts.mock.calls[0]!; expect(delay).toBe(10_000); (timeout as () => void)(); expect(noHost.document.body.textContent).toContain("could not connect")
    const card = mount(); card.deliver(catchUp()); await card.expand(); card.click(".load-latest"); card.receive({ jsonrpc: "2.0", id: 99, method: "ui/resource-teardown" }); await flush()
    expect(card.sent.at(-1)).toEqual({ jsonrpc: "2.0", id: 99, result: {} }); expect(card.query("#root").childElementCount).toBe(0)
    const canceled = mount(); canceled.deliver(result()); canceled.notify("ui/notifications/tool-cancelled", {}); expect(canceled.document.querySelector(".source")).toBeNull(); expect(canceled.document.body.textContent).toContain("cancelled")
  })
})

it("registers self-contained versioned and compatible resources with narrow image CSP", async () => {
  const registerResource = vi.fn(); registerMessageResultsUi({ registerResource } as unknown as McpServer)
  expect(registerResource).toHaveBeenCalledTimes(2)
  expect(registerResource.mock.calls.map((call) => call[1])).toEqual([MESSAGE_RESULTS_RESOURCE_URI, LEGACY_MESSAGE_RESULTS_RESOURCE_URI])
  for (const [, uri, metadata, read] of registerResource.mock.calls) {
    const resource = (await read()).contents[0]; expect(metadata.mimeType).toBe(MESSAGE_RESULTS_MIME_TYPE); expect(resource.uri).toBe(uri); expect(resource.text).toBe(createMessageResultsHtml())
    expect(resource._meta.ui).toEqual({ prefersBorder: true, domain: "https://mcp.inline.chat", csp: { connectDomains: [], resourceDomains: ["https://api.inline.chat"], frameDomains: [] } })
    expect(resource.text).not.toMatch(/\bfetch\(|\bXMLHttpRequest\b|\bWebSocket\b|innerHTML\s*=/)
  }
})
