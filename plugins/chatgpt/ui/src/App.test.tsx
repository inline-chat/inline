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
})

it("renders the resolved thread, exposes only available actions, and attaches explicit bounded selections", async () => {
  expect(container.querySelector("h1")?.textContent).toBe("Feedback on the proposal")
  expect(container.querySelectorAll(".message-row")).toHaveLength(5)
  expect(container.textContent).toContain("ChatGPT is watching for replies")
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
  expect(container.textContent).not.toContain("ChatGPT is watching")
  await act(async () => { reply(delayedId!, { structuredContent: stale }) })
  expect(container.querySelector('[data-message-id="80006"]')?.textContent).toContain(latest.messages.at(-1)!.text)
  expect(container.querySelector("textarea")).toBeNull()
  expect(container.textContent).toContain("You have read access")
  expect(container.textContent).not.toContain("ChatGPT is watching")
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
  expect(container.textContent).not.toContain("ChatGPT is watching")
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
  expect(container.textContent).not.toContain("ChatGPT is watching")
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
