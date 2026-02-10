import { describe, expect, it } from "vitest"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { McpSessionManager } from "./sessions"

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
    await mgr.close(sessionId!)
    expect(externalClosed).toBe(1)
    expect(mgr.get(sessionId!)).toBeNull()
  })
})

