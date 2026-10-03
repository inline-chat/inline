import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, expect, it, vi } from "vitest"
import { sampleThread } from "../scripts/fixtures"
import { App } from "./App"
import { HostBridge } from "./bridge"
import { type ThreadSnapshot } from "./contracts"

let root: Root, container: HTMLDivElement, bridge: HostBridge
let thread: ThreadSnapshot
let requests: Array<{ id: number; method: string; params: any }>
let responder: (request: typeof requests[number]) => unknown
let storedState: unknown
const reply = (id: number, result: unknown) => window.dispatchEvent(new MessageEvent("message", { source: window.parent, data: { jsonrpc: "2.0", id, result } }))
const notify = (result: unknown) => window.dispatchEvent(new MessageEvent("message", { source: window.parent, data: { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: result } }))
const click = async (node: Element) => { await act(async () => { node.dispatchEvent(new MouseEvent("click", { bubbles: true })) }) }
const button = (label: string) => container.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)!
const tools = (name: string) => requests.filter((request) => request.method === "tools/call" && request.params.name === name)
const text = async (value: string) => {
  await act(async () => {
    const input = container.querySelector<HTMLTextAreaElement>("textarea")!
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(input, value)
    input.dispatchEvent(new Event("input", { bubbles: true }))
  })
}

beforeEach(async () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })
  thread = sampleThread()
  requests = []
  storedState = null
  window.openai = { setWidgetState: (value) => { storedState = value } }
  responder = (request) => {
    if (request.method === "ui/initialize") return { protocolVersion: "2026-01-26", hostCapabilities: { updateModelContext: {} }, hostContext: { theme: "light" } }
    if (request.method === "ui/update-model-context") return {}
    if (request.method === "tools/call") {
      if (request.params.name === "messages.send") return { structuredContent: { ok: true, chatId: thread.chat.chatId, messageId: "99999" } }
      return { structuredContent: thread }
    }
  }
  vi.spyOn(window.parent, "postMessage").mockImplementation((request) => {
    requests.push(request)
    if (typeof request.id === "number") queueMicrotask(() => { const response = responder(request); if (response !== undefined) reply(request.id, response) })
  })
  container = document.createElement("div")
  document.body.append(container)
  bridge = new HostBridge()
  root = createRoot(container)
  await act(async () => { root.render(<App bridge={bridge} />) })
  await act(async () => { notify({ structuredContent: thread }) })
})
afterEach(async () => {
  await act(async () => { root.unmount(); bridge.dispose() })
  container.remove()
  delete window.openai
  delete document.documentElement.dataset.theme
  vi.useRealTimers()
})

it("renders the resolved thread, exposes only available actions, and attaches explicit bounded selections", async () => {
  expect(container.querySelector("h1")?.textContent).toBe("Feedback on the proposal")
  expect(container.querySelectorAll(".message-row")).toHaveLength(5)
  expect(container.textContent).toContain("Reply subscription active for this connection")
  expect(container.querySelector("select")).toBeNull()
  expect(tools("conversations.list")).toHaveLength(0)
  await click(button("Select Sam's message for ChatGPT"))
  await click([...container.querySelectorAll("button")].find((node) => node.textContent === "Add to ChatGPT")!)
  const context = requests.find((request) => request.method === "ui/update-model-context")!
  expect(context.params.structuredContent).toEqual({ chatId: "800", messageIds: [thread.messages[1]!.id] })
  expect(context.params.content[0].text).toContain(thread.messages[1]!.text)
  expect(context.params.content[0].text).not.toContain(thread.messages[0]!.text)
})

it("sends a reply once, clears the composer only after a matching receipt, and refreshes the canonical history", async () => {
  await click(button("Reply to Sam's message"))
  await text("Thanks, Sam")
  await click(button("Send message"))
  expect(tools("messages.send")).toHaveLength(1)
  expect(tools("messages.send")[0]!.params.arguments).toEqual({ chatId: "800", text: "Thanks, Sam", replyToMsgId: thread.messages[1]!.id })
  expect(container.querySelector("textarea")?.value).toBe("")
  expect(tools("conversations.open")).toHaveLength(1)
  expect((storedState as any).unconfirmed).toEqual({})
})

it("persists an uncertain send fence, refresh cannot resend or clear it, and remount keeps it blocked", async () => {
  const previous = responder
  responder = (request) => request.params?.name === "messages.send" ? { isError: true, content: [] } : previous(request)
  await text("Did this send?")
  await click(button("Send message"))
  expect(container.querySelector("textarea")?.value).toBe("Did this send?")
  expect(button("Send message").disabled).toBe(true)
  expect(container.textContent).toContain("Delivery couldn’t be confirmed")
  await click(button("Refresh thread"))
  expect(tools("messages.send")).toHaveLength(1)
  expect(button("Send message").disabled).toBe(true)
  await act(async () => { root.unmount(); bridge.dispose() })
  window.openai!.widgetState = storedState
  bridge = new HostBridge()
  root = createRoot(container)
  await act(async () => { root.render(<App bridge={bridge} />) })
  await act(async () => { notify({ structuredContent: thread }) })
  expect(container.querySelector("textarea")?.value).toBe("Did this send?")
  expect(button("Send message").disabled).toBe(true)
  expect(tools("messages.send")).toHaveLength(1)
})

it("keeps a minimal picker of opened threads and rejects a late page from the previous thread", async () => {
  let delayedId: number | null = null
  const previous = responder
  responder = (request) => { if (request.params?.name === "conversations.open") { delayedId = request.id; return undefined } return previous(request) }
  await click(button("Refresh thread"))
  const other = sampleThread("801", "Launch review")
  await act(async () => { notify({ structuredContent: other }) })
  expect(container.querySelectorAll("select option")).toHaveLength(2)
  expect(container.querySelector("select")?.value).toBe("801")
  await act(async () => { reply(delayedId!, { structuredContent: thread }) })
  expect(container.querySelector("select")?.value).toBe("801")
  expect(container.querySelector('[data-message-id="80001"]')).toBeNull()
  expect(tools("conversations.list")).toHaveLength(0)
})

it("rejects a delayed refresh after a newer host snapshot for the same thread", async () => {
  let delayedId: number | null = null
  const previous = responder
  const stale = thread
  responder = (request) => { if (request.params?.name === "conversations.open") { delayedId = request.id; return undefined } return previous(request) }
  await click(button("Select Alex's message for ChatGPT"))
  await click(button("Refresh thread"))
  const latest = {
    ...thread,
    messages: [...thread.messages, { ...thread.messages[1]!, id: "80006", text: "This reply arrived through ChatGPT's newer snapshot." }],
    capabilities: { canSend: false },
    monitoring: { active: false },
  }
  await act(async () => { notify({ structuredContent: latest }) })
  expect(container.querySelector('[data-message-id="80006"]')).not.toBeNull()
  expect(container.querySelector("textarea")).toBeNull()
  expect(container.textContent).not.toContain("Reply subscription active")
  await act(async () => { reply(delayedId!, { structuredContent: stale }) })
  expect(container.querySelector('[data-message-id="80006"]')?.textContent).toContain(latest.messages.at(-1)!.text)
  expect(container.querySelector("textarea")).toBeNull()
  expect(container.textContent).toContain("You have read access")
  expect(container.textContent).not.toContain("Reply subscription active")
  expect(button("Select Alex's message for ChatGPT").getAttribute("aria-pressed")).toBe("true")
  expect(button("Refresh thread").disabled).toBe(false)
})

it("removes deleted recent messages and keeps source selection through refresh", async () => {
  await click(button("Select Alex's message for ChatGPT"))
  const removedId = thread.messages[1]!.id
  thread = { ...thread, messages: thread.messages.filter((message) => message.id !== removedId) }
  await click(button("Refresh thread"))
  expect(container.querySelector(`[data-message-id="${removedId}"]`)).toBeNull()
  expect(button("Select Alex's message for ChatGPT").getAttribute("aria-pressed")).toBe("true")
})

it("does not offer sending or claim monitoring without acknowledged capability and live subscription", async () => {
  thread = { ...thread, capabilities: { canSend: false }, monitoring: { active: true, expiresAt: new Date(Date.now() - 1000).toISOString() } }
  await act(async () => { notify({ structuredContent: thread }) })
  expect(container.querySelector("textarea")).toBeNull()
  expect(container.textContent).toContain("You have read access")
  expect(container.textContent).not.toContain("Reply subscription active")
  expect(container.querySelector('button[title="Reply"]')).toBeNull()
})

it("hydrates a known created thread from an error ask receipt without retrying the question", async () => {
  thread = sampleThread("803", "Question delivery needs review")
  await act(async () => { notify({ isError: true, structuredContent: { chat: thread.chat, questionStatus: "unknown", messageId: null } }) })
  expect(tools("conversations.open").at(-1)?.params.arguments).toEqual({ chatId: "803" })
  expect(container.querySelector("select")?.value).toBe("803")
  expect(container.querySelector('[data-message-id="80301"]')).not.toBeNull()
  expect(tools("messages.send")).toHaveLength(0)
})

it("handles an empty global opener without discovering workspace threads or losing known references", async () => {
  await act(async () => { notify({ structuredContent: { chat: null, details: null, messages: [], nextOffsetId: null } }) })
  expect(container.querySelector("h1")?.textContent).toBe("Feedback on the proposal")
  expect(tools("conversations.list")).toHaveLength(0)
  expect(tools("messages.send")).toHaveLength(0)
})

it("keeps a playing media source stable when refresh rotates a signed URL", async () => {
  const message = thread.messages[1]!
  thread = { ...thread, messages: thread.messages.map((row) => row.id === message.id ? { ...row, media: { kind: "video", id: "90", url: "https://api.inline.chat/media/video?signature=first" } } : row) }
  await act(async () => { notify({ structuredContent: thread }) })
  const player = container.querySelector("video")!
  expect(player.getAttribute("src")).toContain("signature=first")
  thread = { ...thread, messages: thread.messages.map((row) => row.id === message.id ? { ...row, media: { ...row.media!, url: "https://api.inline.chat/media/video?signature=refreshed" } } : row) }
  await click(button("Refresh thread"))
  expect(container.querySelector("video")).toBe(player)
  expect(player.getAttribute("src")).toContain("signature=first")
  await act(async () => { player.dispatchEvent(new Event("error")) })
  expect(player.getAttribute("src")).toContain("signature=refreshed")
})

it("clears a previous watching indicator when a fresh thread snapshot cannot confirm monitoring", async () => {
  const { monitoring: _monitoring, ...withoutMonitoring } = thread
  thread = withoutMonitoring
  await click(button("Refresh thread"))
  expect(tools("conversations.open")).toHaveLength(1)
  expect(container.textContent).not.toContain("Reply subscription active")
})

it("does not restore an old thread before the host supplies its requested initial context", async () => {
  await act(async () => { root.unmount(); bridge.dispose() })
  window.openai!.widgetState = { version: 1, activeChatId: "800", threads: [{ chatId: "800", title: "Previous thread" }], unconfirmed: {} }
  bridge = new HostBridge()
  root = createRoot(container)
  await act(async () => { root.render(<App bridge={bridge} />) })
  expect(tools("conversations.open")).toHaveLength(0)
  const requested = sampleThread("804", "The thread ChatGPT requested")
  await act(async () => { notify({ structuredContent: requested }) })
  expect(container.querySelector("select")?.value).toBe("804")
  expect(container.querySelector('[data-message-id="80001"]')).toBeNull()
  expect(tools("conversations.open")).toHaveLength(0)
})

it("treats an ok send response with no message receipt as unconfirmed", async () => {
  const previous = responder
  responder = (request) => request.params?.name === "messages.send"
    ? { structuredContent: { ok: true, chatId: "800", messageId: null, metadata: { sendMode: "normal" } } } : previous(request)
  await text("Keep this until we have a real receipt")
  await click(button("Send message"))
  expect(container.querySelector("textarea")?.value).toBe("Keep this until we have a real receipt")
  expect(button("Send message").disabled).toBe(true)
  expect((storedState as any).unconfirmed["800"].text).toBe("Keep this until we have a real receipt")
  expect(tools("conversations.open")).toHaveLength(0)
})

const deniedScope = {
  isError: true,
  content: [{ type: "text", text: "Authorization scope missing: this tool requires messages:read." }],
  _meta: { "mcp/www_authenticate": ['Bearer error="insufficient_scope", scope="messages:read"'] },
}

it.each([
  deniedScope,
  { isError: true, content: [{ type: "text", text: "Chat is no longer permitted" }], _meta: { inline: { accessDenied: true } } },
])("clears revoked reads, selected context, drafts, and remembered titles on a denied refresh", async (denied) => {
  await click(button("Select Alex's message for ChatGPT"))
  await click(button("Reply to Sam's message"))
  await text("An unsent draft")
  const previous = responder
  responder = (request) => request.params?.name === "conversations.open" ? denied : previous(request)
  await click(button("Refresh thread"))
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect(container.querySelector(".context-bar")).toBeNull()
  expect(container.querySelector("textarea")).toBeNull()
  expect(container.querySelector(".monitoring-status")).toBeNull()
  expect((storedState as any).threads).toEqual([])
  expect(container.textContent).toContain("Inline access was denied")
  await act(async () => { notify({ structuredContent: thread }) })
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect(container.querySelector("textarea")).toBeNull()
  expect(container.querySelector(".reply-draft")).toBeNull()
  expect((storedState as any).threads).toEqual([])
  expect(tools("conversations.open").at(-1)?.params.arguments).toEqual({ chatId: thread.chat.chatId })
})

it("recovers from denial only with a successful fresh read, preserving the authored send fence", async () => {
  const cached = thread
  const previous = responder
  responder = (request) => request.params?.name === "messages.send" ? { isError: true, content: [] } : previous(request)
  await text("Keep this attempted message fenced")
  await click(button("Send message"))
  await act(async () => { notify(deniedScope) })
  let recoveryId: number | null = null
  responder = (request) => {
    if (request.params?.name === "conversations.open") { recoveryId = request.id; return undefined }
    return previous(request)
  }
  await act(async () => { notify({ structuredContent: cached }) })
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  const fresh = { ...cached, messages: [{ ...cached.messages[0]!, text: "Currently authorized fresh content" }] }
  await act(async () => { reply(recoveryId!, { structuredContent: fresh }) })
  expect(container.querySelectorAll(".message-row")).toHaveLength(1)
  expect(container.textContent).toContain("Currently authorized fresh content")
  expect(container.textContent).not.toContain(cached.messages[1]!.text)
  expect(container.querySelector("textarea")?.value).toBe("Keep this attempted message fenced")
  expect(button("Send message").disabled).toBe(true)
  expect((storedState as any).unconfirmed["800"].text).toBe("Keep this attempted message fenced")
  expect(tools("messages.send")).toHaveLength(1)
  const readCount = tools("conversations.open").length
  await act(async () => { notify({ structuredContent: fresh }) })
  expect(tools("conversations.open")).toHaveLength(readCount)
  expect(container.querySelectorAll(".message-row")).toHaveLength(1)
  thread = { ...fresh, messages: [{ ...fresh.messages[0]!, text: "Newer content from a foreground refresh" }] }
  responder = previous
  await act(async () => { notify({ structuredContent: thread }) })
  expect(container.textContent).not.toContain("Newer content from a foreground refresh")
  await click(button("Refresh thread"))
  expect(container.textContent).toContain("Newer content from a foreground refresh")
  expect(tools("conversations.open")).toHaveLength(readCount + 1)
})

it("keeps the denial gate when a fresh recovery read fails transiently", async () => {
  await act(async () => { notify(deniedScope) })
  const previous = responder
  responder = (request) => request.params?.name === "conversations.open"
    ? { isError: true, content: [{ type: "text", text: "Temporary transport failure" }] } : previous(request)
  await act(async () => { notify({ structuredContent: thread }) })
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect((storedState as any).threads).toEqual([])
  responder = (request) => request.params?.name === "conversations.open" ? deniedScope : previous(request)
  await act(async () => { notify({ structuredContent: thread }) })
  expect(tools("conversations.open")).toHaveLength(2)
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect(container.textContent).toContain("Inline access was denied")
})

it("requires fresh authorization for a late revoked thread even after another thread recovers", async () => {
  const revoked = thread
  const allowed = sampleThread("801", "Fresh authorized thread")
  await act(async () => { notify(deniedScope) })
  const previous = responder
  responder = (request) => request.params?.name === "conversations.open"
    ? request.params.arguments.chatId === "801" ? { structuredContent: allowed } : deniedScope
    : previous(request)
  await act(async () => { notify({ structuredContent: allowed }) })
  expect(container.querySelector('[data-message-id="80101"]')).not.toBeNull()
  const { capabilities: _capabilities, ...dataOnlyPage } = revoked
  await act(async () => { notify({ structuredContent: dataOnlyPage }) })
  expect(tools("conversations.open")).toHaveLength(1)
  expect(container.querySelector('[data-message-id="80101"]')).not.toBeNull()
  expect(container.querySelector('[data-message-id="80001"]')).toBeNull()
  await act(async () => { notify({ structuredContent: revoked }) })
  expect(tools("conversations.open").map((request) => request.params.arguments.chatId)).toEqual(["801", "800"])
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect((storedState as any).threads).toEqual([])
})

it("does not restore a cached ask receipt's title before a fresh authorized read", async () => {
  await act(async () => { notify(deniedScope) })
  let recoveryId: number | null = null
  const previous = responder
  responder = (request) => {
    if (request.params?.name === "conversations.open") { recoveryId = request.id; return undefined }
    return previous(request)
  }
  await act(async () => { notify({ isError: true, structuredContent: { chat: { ...thread.chat, title: "Revoked cached title" }, questionStatus: "unknown" } }) })
  expect(container.textContent).not.toContain("Revoked cached title")
  expect((storedState as any).threads).toEqual([])
  expect(tools("conversations.open").at(-1)?.params.arguments).toEqual({ chatId: "800" })
  await act(async () => { reply(recoveryId!, deniedScope) })
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect((storedState as any).threads).toEqual([])
})

it("coalesces recovery notifications and keeps a newer same-target read owned when a stale read finishes", async () => {
  await act(async () => { notify(deniedScope) })
  const previous = responder
  responder = (request) => request.params?.name === "conversations.open" ? undefined : previous(request)
  const other = sampleThread("801")
  await act(async () => { notify({ structuredContent: thread }) })
  await act(async () => { notify({ structuredContent: other }) })
  await act(async () => { notify({ structuredContent: thread }) })
  const recoveryReads = tools("conversations.open")
  expect(recoveryReads).toHaveLength(3)
  await act(async () => { reply(recoveryReads[0]!.id, { structuredContent: thread }) })
  await act(async () => { notify({ structuredContent: thread }) })
  expect(tools("conversations.open")).toHaveLength(3)
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  await act(async () => { reply(recoveryReads[2]!.id, { structuredContent: thread }) })
  await act(async () => { reply(recoveryReads[1]!.id, { structuredContent: other }) })
  expect(container.querySelector('[data-message-id="80001"]')).not.toBeNull()
  expect(container.querySelector('[data-message-id="80101"]')).toBeNull()
  await act(async () => { notify({ structuredContent: thread }) })
  expect(tools("conversations.open")).toHaveLength(3)
})

it("preserves cached messages and selections for a transient read failure", async () => {
  await click(button("Select Alex's message for ChatGPT"))
  const previous = responder
  responder = (request) => request.params?.name === "conversations.open"
    ? { isError: true, content: [{ type: "text", text: "Transport temporarily unavailable" }] } : previous(request)
  await click(button("Refresh thread"))
  expect(container.querySelectorAll(".message-row")).toHaveLength(5)
  expect(container.querySelector(".context-bar")).not.toBeNull()
  expect(container.textContent).toContain("The latest messages couldn’t be loaded")
})

it("fences an outstanding cached read after a host denial notification", async () => {
  let delayedId: number | null = null
  const previous = responder
  responder = (request) => {
    if (request.params?.name === "conversations.open") { delayedId = request.id; return undefined }
    return previous(request)
  }
  await click(button("Refresh thread"))
  await act(async () => { notify(deniedScope) })
  await act(async () => { reply(delayedId!, { structuredContent: thread }) })
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect(container.querySelector("textarea")).toBeNull()
  expect(container.textContent).toContain("Inline access was denied")
})

it("clears cached rows on a canonical JSON-RPC HTTP denial", async () => {
  let delayedId: number | null = null
  const previous = responder
  responder = (request) => {
    if (request.params?.name === "conversations.open") { delayedId = request.id; return undefined }
    return previous(request)
  }
  await click(button("Refresh thread"))
  await act(async () => {
    window.dispatchEvent(new MessageEvent("message", { source: window.parent,
      data: { jsonrpc: "2.0", id: delayedId, error: { code: -32000, message: "Unauthorized", data: { status: 401 } } },
    }))
  })
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect(container.textContent).toContain("Inline access was denied")
})

it("clears cached rows when earlier history access is revoked", async () => {
  thread = { ...thread, nextOffsetId: thread.messages[0]!.id }
  await act(async () => { notify({ structuredContent: thread }) })
  const previous = responder
  responder = (request) => request.params?.name === "messages.list" ? deniedScope : previous(request)
  await click(container.querySelector(".load-older")!)
  expect(tools("messages.list")[0]!.params.arguments.offsetId).toBe(thread.messages[0]!.id)
  expect(container.querySelectorAll(".message-row")).toHaveLength(0)
  expect(container.textContent).toContain("Inline access was denied")
})

it("keeps an uncertain send blocked after picker eviction and a remount", async () => {
  const original = thread
  const previous = responder
  responder = (request) => request.params?.name === "messages.send" ? { isError: true, content: [] } : previous(request)
  await text("Check whether this question was delivered")
  await click(button("Send message"))
  for (let id = 801; id <= 812; id++) {
    thread = sampleThread(String(id))
    await act(async () => { notify({ structuredContent: thread }) })
  }
  expect((storedState as any).threads).toHaveLength(12)
  expect((storedState as any).threads.some((item: any) => item.chatId === original.chat.chatId)).toBe(false)
  await act(async () => { root.unmount(); bridge.dispose() })
  window.openai!.widgetState = storedState
  bridge = new HostBridge()
  root = createRoot(container)
  await act(async () => { root.render(<App bridge={bridge} />) })
  await act(async () => { notify({ structuredContent: original }) })
  expect(container.querySelector("textarea")?.value).toBe("Check whether this question was delivered")
  expect(button("Send message").disabled).toBe(true)
  expect(tools("messages.send")).toHaveLength(1)
})

it("stops new sends instead of discarding an unresolved receipt when the fence limit is reached", async () => {
  const previous = responder
  responder = (request) => request.params?.name === "messages.send" ? { isError: true, content: [] } : previous(request)
  for (let id = 800; id < 812; id++) {
    thread = sampleThread(String(id))
    await act(async () => { notify({ structuredContent: thread }) })
    await text(`Question for thread ${id}`)
    await click(button("Send message"))
  }
  thread = sampleThread("812")
  await act(async () => { notify({ structuredContent: thread }) })
  await text("Another question")
  expect(button("Send message").disabled).toBe(true)
  expect(Object.keys((storedState as any).unconfirmed)).toHaveLength(12)
  expect(tools("messages.send")).toHaveLength(12)
  expect(container.textContent).toContain("resolve it before sending more messages")
})

it("clears only the chosen send fence without resending, then sends a separately authored message", async () => {
  const original = thread
  const previous = responder
  responder = (request) => request.params?.name === "messages.send" ? { isError: true, content: [] } : previous(request)
  await click(button("Reply to Sam's message"))
  await text("Original uncertain reply")
  await click(button("Send message"))
  thread = sampleThread("801")
  await act(async () => { notify({ structuredContent: thread }) })
  await text("Another uncertain send")
  await click(button("Send message"))
  thread = original
  await act(async () => { notify({ structuredContent: original }) })
  await click([...container.querySelectorAll("button")].find((node) => node.textContent === "Continue with a new message")!)
  expect(tools("messages.send")).toHaveLength(2)
  expect((storedState as any).unconfirmed["800"]).toBeUndefined()
  expect((storedState as any).unconfirmed["801"].text).toBe("Another uncertain send")
  expect(container.querySelector("textarea")?.value).toBe("")
  expect(container.querySelector(".reply-draft")).toBeNull()
  responder = previous
  await text("A separately authored new message")
  await click(button("Send message"))
  expect(tools("messages.send")).toHaveLength(3)
  expect(tools("messages.send").at(-1)?.params.arguments).toEqual({ chatId: "800", text: "A separately authored new message" })
  expect((storedState as any).unconfirmed["801"].text).toBe("Another uncertain send")
})

it("expires the connection subscription indicator even when foreground polling never responds", async () => {
  await act(async () => { root.unmount(); bridge.dispose() })
  vi.useFakeTimers()
  bridge = new HostBridge()
  root = createRoot(container)
  await act(async () => { root.render(<App bridge={bridge} />) })
  thread = { ...thread, monitoring: { active: true, expiresAt: new Date(Date.now() + 20_000).toISOString() } }
  await act(async () => { notify({ structuredContent: thread }) })
  const previous = responder
  responder = (request) => request.params?.name === "conversations.open" ? undefined : previous(request)
  expect(container.textContent).toContain("Reply subscription active for this connection")
  await act(async () => { await vi.advanceTimersByTimeAsync(20_001) })
  expect(tools("conversations.open")).toHaveLength(1)
  expect(container.querySelector(".monitoring-status")).toBeNull()
})

it("does not adopt a data-only pagination notification as a fresh thread view", async () => {
  const older = { ...thread.messages[0]!, id: "79999", text: "An older page" }
  await act(async () => { notify({ structuredContent: { chat: thread.chat, messages: [older], nextOffsetId: null } }) })
  expect(container.querySelectorAll(".message-row")).toHaveLength(5)
  expect(container.querySelector('[data-message-id="80005"]')).not.toBeNull()
  expect(container.querySelector('[data-message-id="79999"]')).toBeNull()
})
