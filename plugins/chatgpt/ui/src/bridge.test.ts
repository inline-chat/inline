import { afterEach, expect, it, vi } from "vitest"
import { HostBridge } from "./bridge"

const bridges: HostBridge[] = []
afterEach(() => { for (const bridge of bridges.splice(0)) bridge.dispose(); vi.useRealTimers() })
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
