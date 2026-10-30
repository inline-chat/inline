import { describe, expect, it, vi } from "vitest"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { McpSessionManager } from "./sessions"
import { MAX_MCP_REQUEST_BYTES } from "./request-limits"

const initRequest = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "vitest", version: "0.0.0" },
  },
}

describe("McpSessionManager", () => {
  it("bounds HTTP bodies and batches while preserving upload-sized requests", async () => {
    const manager = new McpSessionManager()
    const server = new McpServer({ name: "bounded-test", version: "0" })
    const { transport, close } = manager.createTransport({
      grantId: "g1", nowMs: Date.now(), server, close: async () => {},
    })
    await server.connect(transport)
    const post = (body: string, headers: Record<string, string> = {}) => transport.handleRequest(new Request("http://localhost/mcp", {
      method: "POST", headers: { accept: "application/json, text/event-stream", "content-type": "application/json", ...headers }, body,
    }))
    try {
      const tooLarge = await post("{}", { "content-length": String(MAX_MCP_REQUEST_BYTES + 1) })
      expect(tooLarge.status).toBe(413)
      const batch = await post(JSON.stringify(Array.from({ length: 101 }, (_, id) => ({ jsonrpc: "2.0", id, method: "ping" }))))
      expect(batch.status).toBe(400)
      const uploadSized = await post(JSON.stringify({ ...initRequest, params: { ...initRequest.params, _meta: { padding: "x".repeat(5 * 1024 * 1024) } } }))
      expect(uploadSized.status).toBe(200)
    } finally {
      await close()
    }
  })

  it("closes uninitialized resources exactly once even with concurrent cleanup", async () => {
    const manager = new McpSessionManager()
    const server = new McpServer({ name: "setup-test", version: "0" })
    let closed = 0
    const managed = manager.createTransport({
      grantId: "g1", nowMs: Date.now(), server,
      close: async () => { closed++ },
    })
    await Promise.all([managed.close(), managed.close()])
    expect(closed).toBe(1)
  })

  it("stores session on initialize and closes cleanly", async () => {
    const mgr = new McpSessionManager({ idleTimeoutMs: 60_000 })

    const server = new McpServer({ name: "test", version: "0" })
    // Force server.close() to throw to cover the best-effort close path.
    ;(server as any).close = async () => {
      throw new Error("boom")
    }

    let externalClosed = 0
    const { transport } = mgr.createTransport({
      grantId: "g1",
      nowMs: Date.now(),
      server,
      close: async () => {
        externalClosed++
      },
    })

    await server.connect(transport)

    const res = await transport.handleRequest(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          accept: "application/json, text/event-stream",
          "content-type": "application/json",
        },
        body: JSON.stringify(initRequest),
      }),
    )

    expect(res.status).toBe(200)
    const sessionId = res.headers.get("mcp-session-id")
    expect(sessionId).toBeTruthy()

    const s = mgr.get(sessionId!)
    expect(s?.grantId).toBe("g1")

    mgr.touch(sessionId!, Date.now() + 1)
    const closeTransport = vi.spyOn(transport, "close")
    await mgr.close(sessionId!)
    expect(closeTransport).toHaveBeenCalledOnce()
    expect(externalClosed).toBe(1)
    expect(mgr.get(sessionId!)).toBeNull()
  })

  it("closes idle sessions automatically", async () => {
    const mgr = new McpSessionManager({ idleTimeoutMs: 20 })
    const server = new McpServer({ name: "idle-test", version: "0" })

    let externalClosed = 0
    const { transport } = mgr.createTransport({
      grantId: "g2",
      nowMs: Date.now(),
      server,
      close: async () => {
        externalClosed++
      },
    })

    await server.connect(transport)

    const res = await transport.handleRequest(
      new Request("http://localhost/mcp", {
        method: "POST",
        headers: {
          accept: "application/json, text/event-stream",
          "content-type": "application/json",
        },
        body: JSON.stringify(initRequest),
      }),
    )

    const sessionId = res.headers.get("mcp-session-id")
    expect(sessionId).toBeTruthy()
    expect(mgr.get(sessionId!)).not.toBeNull()

    await new Promise((resolve) => setTimeout(resolve, 80))

    expect(mgr.get(sessionId!)).toBeNull()
    expect(externalClosed).toBeGreaterThanOrEqual(1)
  })
})
