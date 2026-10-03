import { afterEach, expect, it, vi } from "vitest"
import { HostBridge } from "./bridge"

const bridges: HostBridge[] = []
afterEach(() => { for (const bridge of bridges.splice(0)) bridge.dispose(); delete window.openai; vi.useRealTimers() })
function hostReply(id: number, result: unknown, source: MessageEventSource = window.parent) {
  window.dispatchEvent(new MessageEvent("message", { source, data: { jsonrpc: "2.0", id, result } }))
}
function setup() {
  const requests: Record<string, unknown>[] = []
  vi.spyOn(window.parent, "postMessage").mockImplementation((value: unknown) => { requests.push(value as Record<string, unknown>) })
  const bridge = new HostBridge()
  bridges.push(bridge)
  return { bridge, requests }
}
const initialized = { protocolVersion: "2026-01-26", hostCapabilities: { updateModelContext: {} }, hostContext: { theme: "dark" } }

it("uses the standard lifecycle and rejects messages from any window except the parent", async () => {
  const { bridge, requests } = setup()
  const ready = bridge.initialize()
  expect(requests[0]).toMatchObject({ method: "ui/initialize", params: { protocolVersion: "2026-01-26" } })
  hostReply(1, initialized, {} as Window)
  expect(bridge.hostState.status).toBe("connecting")
  hostReply(1, initialized)
  await ready
  expect(bridge.hostState).toEqual({ status: "ready", theme: "dark", canAttachContext: true })
  expect(requests.at(-1)).toMatchObject({ method: "ui/notifications/initialized" })
  const result = bridge.callTool("messages.list", { chatId: "10", limit: 50 })
  await Promise.resolve()
  expect(requests.at(-1)).toMatchObject({ method: "tools/call", params: { name: "messages.list", arguments: { chatId: "10", limit: 50 } } })
  hostReply(2, { structuredContent: { messages: [] } })
  await expect(result).resolves.toEqual({ structuredContent: { messages: [] } })
})

it("never retries a timed-out write, and teardown rejects pending work", async () => {
  vi.useFakeTimers()
  const { bridge, requests } = setup()
  const ready = bridge.initialize()
  hostReply(1, initialized)
  await ready
  const send = bridge.callTool("messages.send", { chatId: "10", text: "A message" })
  const timedOut = expect(send).rejects.toThrow("timed out")
  await vi.advanceTimersByTimeAsync(120_000)
  await timedOut
  expect(requests.filter((request) => request.method === "tools/call")).toHaveLength(1)
  const read = bridge.callTool("messages.list", { chatId: "10" })
  const closed = expect(read).rejects.toThrow("closed")
  await Promise.resolve()
  window.dispatchEvent(new MessageEvent("message", { source: window.parent, data: { jsonrpc: "2.0", id: "teardown", method: "ui/resource-teardown" } }))
  await closed
  expect(bridge.hostState.status).toBe("closed")
  expect(requests.at(-1)).toMatchObject({ id: "teardown", result: {} })
  expect(vi.getTimerCount()).toBe(0)
})

it("preserves the canonical JSON-RPC denial data for the UI", async () => {
  const { bridge } = setup()
  const ready = bridge.initialize()
  hostReply(1, initialized)
  await ready
  const read = bridge.callTool("conversations.open", { chatId: "10" })
  const rejected = expect(read).rejects.toMatchObject({ rpcError: { code: -32000, data: { status: 403 } } })
  await Promise.resolve()
  window.dispatchEvent(new MessageEvent("message", { source: window.parent,
    data: { jsonrpc: "2.0", id: 2, error: { code: -32000, message: "Denied", data: { status: 403 } } },
  }))
  await rejected
})

it("replays an early standard result to a subscriber mounted after initialization", async () => {
  const { bridge } = setup()
  const result = { structuredContent: { chat: { chatId: "10", title: "Requested thread" } } }
  window.openai = { toolOutput: { chat: { chatId: "11", title: "Older snapshot" } } }
  const ready = bridge.initialize()
  window.dispatchEvent(new MessageEvent("message", { source: window.parent, data: { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: result } }))
  window.dispatchEvent(new CustomEvent("openai:set_globals", { detail: { globals: { toolOutput: { chat: { chatId: "11", title: "Older snapshot" } } } } }))
  hostReply(1, initialized)
  await ready
  const events: unknown[] = []
  bridge.subscribe((event) => events.push(event))
  expect(events).toEqual([{ kind: "state", state: bridge.hostState }, { kind: "result", result }])
})

it("prioritizes launch denial over a queued success and removes globals listeners on teardown", async () => {
  const { bridge } = setup()
  const denied = { isError: true, _meta: { inline: { accessDenied: true } } }
  window.openai = { toolOutput: { chat: { chatId: "10", title: "Cached title" } }, toolResponseMetadata: { status: "error", mcp_tool_result: denied }, displayMode: "fullscreen",
    widgetState: { version: 1, activeChatId: "10", threads: [{ chatId: "10", title: "Cached title" }], unconfirmed: { "10": { text: "An uncertain send" } } },
  }
  expect(bridge.widgetState).toEqual({ version: 1, activeChatId: null, threads: [], unconfirmed: { "10": { text: "An uncertain send" } } })
  const events: Array<{ kind: string; result?: unknown }> = []
  bridge.subscribe((event) => events.push(event))
  const ready = bridge.initialize()
  window.dispatchEvent(new MessageEvent("message", { source: window.parent, data: { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: { structuredContent: { chat: { chatId: "10", title: "Cached title" } } } } }))
  hostReply(1, initialized)
  await ready
  expect(events.filter((event) => event.kind === "result")).toEqual([{ kind: "result", result: denied }])
  expect(bridge.hostState.displayMode).toBe("fullscreen")
  bridge.dispose()
  const count = events.length
  window.dispatchEvent(new CustomEvent("openai:set_globals", { detail: { globals: { displayMode: "inline", toolOutput: {} } } }))
  expect(events).toHaveLength(count)
})

it("cannot revive a disposed bridge when the initialize response resolves immediately before teardown", async () => {
  const { bridge, requests } = setup()
  const ready = bridge.initialize()
  const rejected = expect(ready).rejects.toThrow("closed")
  hostReply(1, initialized)
  bridge.dispose()
  await rejected
  expect(bridge.hostState.status).toBe("closed")
  expect(requests.filter((request) => request.method === "ui/notifications/initialized")).toHaveLength(0)
})

it("immediately replays a connecting denial to a later subscriber without waiting for readiness", () => {
  const { bridge } = setup()
  const denied = { isError: true, _meta: { inline: { accessDenied: true } } }
  window.dispatchEvent(new MessageEvent("message", { source: window.parent, data: { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: denied } }))
  const events: unknown[] = []
  bridge.subscribe((event) => events.push(event))
  expect(bridge.hostState.status).toBe("connecting")
  expect(events).toEqual([{ kind: "result", result: denied }])
})
