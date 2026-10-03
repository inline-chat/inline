import { afterEach, describe, expect, it, vi } from "vitest"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { McpError } from "@modelcontextprotocol/sdk/types.js"
import * as z from "zod/v4"
import { EventsRpcError, type EventsProxy } from "./events-proxy"
import { handleModernRequest, isModernRequest, MODERN_MCP_VERSION, modernRequestHeaderHint } from "./modern"

const metadata = {
  "io.modelcontextprotocol/protocolVersion": MODERN_MCP_VERSION,
  "io.modelcontextprotocol/clientCapabilities": {},
}
const auth: AuthInfo = { token: "test-bearer", clientId: "test-client", scopes: ["messages:read"] }
const events: EventsProxy = { request: async () => ({ events: [] }) }
const headerValidationCases: Array<{ headers: Record<string, string>; params: Record<string, unknown> }> = [
  { headers: { "mcp-protocol-version": "" }, params: {} },
  { headers: { "mcp-protocol-version": "2025-11-25" }, params: {} },
  { headers: { "mcp-method": "TOOLS/LIST" }, params: {} },
  { headers: { "mcp-method": "" }, params: {} },
]

function request(method: string, params: Record<string, unknown> = {}, headers: HeadersInit = {}): Request {
  const source = method === "resources/read" ? params.uri : params.name
  return new Request("https://mcp.inline.chat/mcp/v2", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      "mcp-protocol-version": MODERN_MCP_VERSION,
      "mcp-method": method,
      ...(typeof source === "string" ? { "mcp-name": source } : {}),
      ...Object.fromEntries(new Headers(headers)),
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: "request-1", method, params: { _meta: metadata, ...params } }),
  })
}

function serverWithTools(): McpServer {
  const server = new McpServer({ name: "test", version: "1" })
  server.registerTool("echo", { inputSchema: { text: z.string() } }, async ({ text }, extra) => ({
    content: [{ type: "text", text }],
    _meta: { clientId: extra.authInfo?.clientId },
  }))
  server.registerResource("unicode", new URL("ui://inline/نظر.html").toString(), {}, async (uri, extra) => ({
    contents: [{ uri: uri.toString(), text: extra.authInfo?.clientId ?? "missing-auth" }],
  }))
  return server
}

async function handle(req: Request, overrides: Partial<Parameters<typeof handleModernRequest>[0]> = {}): Promise<Response> {
  return handleModernRequest({ req, auth, events, createServer: serverWithTools, instructions: "Test instructions", ...overrides })
}

describe("modern stateless MCP transport", () => {
  afterEach(() => vi.restoreAllMocks())

  it("discovers without constructing SDK or Inline resources", async () => {
    const createServer = vi.fn(serverWithTools)
    const response = await handle(request("server/discover"), { createServer })
    expect(response.status).toBe(200)
    expect(response.headers.get("mcp-session-id")).toBeNull()
    expect(await response.json()).toMatchObject({
      id: "request-1", result: {
        resultType: "complete", supportedVersions: [MODERN_MCP_VERSION],
        capabilities: { tools: {}, resources: {}, events: {} }, instructions: "Test instructions",
        _meta: { "io.modelcontextprotocol/serverInfo": { name: "inline" } },
      },
    })
    expect(createServer).not.toHaveBeenCalled()
  })

  it("executes the SDK tool registry without initialize or a session", async () => {
    const response = await handle(request("tools/list"))
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ result: { resultType: "complete", tools: [{ name: "echo" }] } })
    const called = await handle(request("tools/call", { name: "echo", arguments: { text: "Hello" } }))
    expect(called.status).toBe(200)
    expect(called.headers.get("mcp-session-id")).toBeNull()
    expect(await called.json()).toMatchObject({ result: {
      resultType: "complete", content: [{ type: "text", text: "Hello" }],
      _meta: { clientId: "test-client", "io.modelcontextprotocol/serverInfo": { name: "inline" } },
    } })
  })

  // MCP 2026-07-28 CacheableResult requires both fields on these responses.
  // Exercise serialized RPC responses, including legacy SDK registrations.
  it.each(["server/discover", "tools/list", "resources/list", "resources/templates/list", "resources/read"])("provides private, immediately stale cache metadata for %s", async (method) => {
    const uri = new URL("ui://inline/نظر.html").toString()
    const response = await handle(request(method, method === "resources/read" ? { uri } : {}))
    expect(response.status).toBe(200)
    const body = await response.json()
    expect(body.result).toMatchObject({ resultType: "complete", ttlMs: 0, cacheScope: "private" })
    expect(body.error).toBeUndefined()
  })

  it("does not mark tool execution or event subscription results as cacheable", async () => {
    for (const [method, params] of [
      ["tools/call", { name: "echo", arguments: { text: "Hello" } }],
      ["events/subscribe", {}],
    ] as const) {
      const response = await handle(request(method, params))
      expect(response.status).toBe(200)
      const body = await response.json()
      expect(body.result).not.toHaveProperty("ttlMs")
      expect(body.result).not.toHaveProperty("cacheScope")
    }
  })

  it("decodes a UTF-8 Base64 sentinel before executing the SDK resource callback", async () => {
    const uri = "ui://inline/نظر.html"
    const response = await handle(request("resources/read", { uri }, { "mcp-name": `=?base64?${Buffer.from(uri).toString("base64")}?=` }))
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ result: { resultType: "complete", contents: [{ uri: new URL(uri).toString(), text: "test-client" }] } })
    expect((await handle(request("resources/list"))).status).toBe(200)
    const templates = await handle(request("resources/templates/list"))
    expect(await templates.json()).toMatchObject({ result: { resultType: "complete", resourceTemplates: [] } })
  })

  it.each(["events/list", "events/subscribe", "events/unsubscribe"])("proxies %s without constructing SDK resources", async (method) => {
    const createServer = vi.fn(serverWithTools)
    const invoke = vi.fn(async () => ({ id: "subscription-1", cursor: "opaque", truncated: false, refreshBefore: null }))
    const response = await handle(request(method, { name: "message.created", arguments: { chatId: "7" } }), { createServer, events: { request: invoke } })
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ result: { resultType: "complete", cursor: "opaque" } })
    expect(invoke).toHaveBeenCalledWith(method, expect.objectContaining({ name: "message.created", arguments: { chatId: "7" } }))
    expect(createServer).not.toHaveBeenCalled()
  })

  it("preserves a backend event error and omits subscription credentials from the response", async () => {
    const response = await handle(request("events/subscribe"), {
      events: { request: async () => { throw new EventsRpcError(-32602, "Unauthorized selector", { field: "chatId" }) } },
    })
    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ jsonrpc: "2.0", id: "request-1", error: { code: -32602, message: "Unauthorized selector", data: { field: "chatId" } } })
  })

  it.each(headerValidationCases)("rejects missing or mismatched standard headers before construction: %j", async ({ headers, params }) => {
    const createServer = vi.fn(serverWithTools)
    const response = await handle(request("tools/list", params, headers), { createServer })
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: -32020 } })
    expect(createServer).not.toHaveBeenCalled()
  })

  it.each(["", "different", "=?base64?@@?=", "=?base64?ZWNobw?=", "=?base64?/w==?="])("rejects malformed or mismatched names: %s", async (name) => {
    const response = await handle(request("tools/call", { name: "echo", arguments: { text: "Hi" } }, { "mcp-name": name }))
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: -32020 } })
  })

  it.each([undefined, {}, { ...metadata, "io.modelcontextprotocol/clientCapabilities": [] }, { ...metadata, "io.modelcontextprotocol/clientCapabilities": { sampling: true } }, { ...metadata, "io.modelcontextprotocol/clientInfo": { name: "test" } }, { ...metadata, "io.modelcontextprotocol/logLevel": ["info"] }])("rejects malformed per-request metadata: %j", async (meta) => {
    const response = await handle(request("tools/list", { _meta: meta }))
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: -32602 } })
  })

  it("returns the normative unsupported-version code and negotiation data", async () => {
    const response = await handle(request("tools/list", { _meta: { ...metadata, "io.modelcontextprotocol/protocolVersion": "future" } }, { "mcp-protocol-version": "future" }))
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: -32022, data: { requested: "future", supported: [MODERN_MCP_VERSION] } } })
  })

  it.each(["initialize", "ping", "prompts/list", "events/poll", "events/stream", "subscriptions/listen", "not/a/method"])("returns 404 for unsupported modern method %s", async (method) => {
    const response = await handle(request(method))
    expect(response.status).toBe(404)
    expect(await response.json()).toMatchObject({ error: { code: -32601 } })
  })

  it("returns protocol errors for unknown tools and resources while keeping validation failures actionable", async () => {
    const unknown = await handle(request("tools/call", { name: "missing", arguments: {} }))
    expect(unknown.status).toBe(400)
    expect(await unknown.json()).toMatchObject({ error: { code: -32602 } })
    const resource = await handle(request("resources/read", { uri: "ui://missing.html" }))
    expect(resource.status).toBe(400)
    expect(await resource.json()).toMatchObject({ error: { code: -32602 } })
    const invalid = await handle(request("tools/call", { name: "echo", arguments: { text: 42 } }))
    expect(invalid.status).toBe(200)
    expect(await invalid.json()).toMatchObject({ result: { resultType: "complete", isError: true } })
  })

  it.each([{ legacy: -32002, modern: -32602, status: 400 }, { legacy: -32042, modern: -32603, status: 500 }])("does not emit removed legacy error codes: %j", async ({ legacy, modern, status }) => {
    const createServer = () => {
      const server = new McpServer({ name: "test", version: "1" })
      server.registerResource("legacy-error", "ui://inline/legacy-error.html", {}, async () => { throw new McpError(legacy, "Legacy callback failed") })
      return server
    }
    const response = await handle(request("resources/read", { uri: "ui://inline/legacy-error.html" }), { createServer })
    expect(response.status).toBe(status)
    expect(await response.json()).toMatchObject({ error: { code: modern } })
  })

  it("validates nested mirrored tool parameters from the actual SDK schema", async () => {
    const createServer = () => {
      const server = new McpServer({ name: "test", version: "1" })
      server.registerTool("tenant", { inputSchema: {
        tenant: z.string().meta({ "x-mcp-header": "Tenant" }),
        options: z.object({ count: z.number().int().meta({ "x-mcp-header": "Count" }) }),
      } }, async () => ({ content: [] }))
      return server
    }
    const params = { name: "tenant", arguments: { tenant: "世界", options: { count: 42 } } }
    const headers = { "mcp-param-tenant": "=?base64?5LiW55WM?=", "mcp-param-count": "42.0" }
    expect((await handle(request("tools/call", params, headers), { createServer })).status).toBe(200)
    const response = await handle(request("tools/call", params, { ...headers, "mcp-param-count": "43" }), { createServer })
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: -32020 } })
  })

  it.each(["GET", "DELETE"])("refuses %s instead of opening a modern session stream", async (method) => {
    const response = await handle(new Request("https://mcp.inline.chat/mcp/v2", { method }))
    expect(response.status).toBe(405)
    expect(response.headers.get("allow")).toBe("POST")
  })

  it.each(["not-json", "[]", '{"jsonrpc":"2.0","method":"tools/list"}', '{"jsonrpc":"2.0","id":null,"method":"tools/list"}'])("rejects malformed/batched/notification traffic: %s", async (body) => {
    const req = new Request("https://mcp.inline.chat/mcp/v2", { method: "POST", body })
    const response = await handle(req)
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: body === "not-json" ? -32700 : -32600 } })
  })

  it("rejects oversized bodies before dispatch", async () => {
    const req = new Request("https://mcp.inline.chat/mcp/v2", { method: "POST", headers: { "content-length": String(41 * 1024 * 1024) }, body: "{}" })
    const createServer = vi.fn(serverWithTools)
    expect((await handle(req, { createServer })).status).toBe(413)
    expect(createServer).not.toHaveBeenCalled()
  })

  it.each([false, true])("closes and cancels the SDK handler on abort without retrying the write (close failure: %s)", async (closeFailure) => {
    const abort = new AbortController()
    let started!: () => void
    const invoked = new Promise<void>((resolve) => { started = resolve })
    let handlerSignal: AbortSignal | undefined
    const write = vi.fn(async (_args: Record<string, never>, extra: { signal: AbortSignal }) => {
      handlerSignal = extra.signal
      started()
      await new Promise<void>((resolve) => extra.signal.addEventListener("abort", () => resolve(), { once: true }))
      return { content: [] }
    })
    const server = new McpServer({ name: "test", version: "1" })
    server.registerTool("write", { inputSchema: {} }, write)
    const close = vi.spyOn(server, "close")
    if (closeFailure) close.mockRejectedValueOnce(new Error("injected server close failure"))
    const original = request("tools/call", { name: "write", arguments: {} })
    const pending = handle(new Request(original, { signal: abort.signal }), { createServer: () => server })
    await invoked
    abort.abort()
    const response = await pending
    expect(response.status).toBe(500)
    expect(await response.json()).toMatchObject({ error: { code: -32603, message: expect.stringContaining("confirm any write outcome") } })
    expect(handlerSignal?.aborted).toBe(true)
    expect(close).toHaveBeenCalledTimes(1)
    expect(write).toHaveBeenCalledTimes(1)
  })

  it("keeps recognized legacy versions in the legacy lane", async () => {
    for (const version of ["2024-10-07", "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]) {
      const req = new Request("https://mcp.inline.chat/mcp", { method: "POST", headers: { "mcp-protocol-version": version }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: version, capabilities: {} } }) })
      expect(modernRequestHeaderHint(req)).toBeUndefined()
      expect(await isModernRequest(req)).toBe(false)
    }
    const modern = request("tools/list", {}, { "mcp-session-id": "old-session" })
    expect(await isModernRequest(modern)).toBe(true)
    const missingHeaders = new Request("https://mcp.inline.chat/mcp", { method: "POST", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: metadata } }) })
    expect(await isModernRequest(missingHeaders)).toBe(true)
  })
})
