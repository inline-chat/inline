import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { createApp } from "../app"
import * as inlineApi from "../inline/inline-api"
import { MODERN_MCP_VERSION } from "./modern"

const meta = {
  "io.modelcontextprotocol/protocolVersion": MODERN_MCP_VERSION,
  "io.modelcontextprotocol/clientCapabilities": {},
}

function introspection(scope = "messages:read spaces:read messages:write") {
  return {
    active: true, grant_id: "grant-1", client_id: "client-1", scope, aud: "http://localhost:8791",
    exp: Math.floor(Date.now() / 1000) + 3600, inline_user_id: "1", space_ids: ["10"],
    allow_dms: false, allow_home_threads: false, inline_token: "1:inline-token",
  }
}

function modernRequest(method: string, params: Record<string, unknown> = {}, extraHeaders: HeadersInit = {}): Request {
  const name = method === "resources/read" ? params.uri : params.name
  return new Request("http://localhost/mcp/v2", {
    method: "POST",
    headers: {
      authorization: "Bearer oauth-test-token", "content-type": "application/json", accept: "application/json, text/event-stream",
      "mcp-protocol-version": MODERN_MCP_VERSION, "mcp-method": method,
      ...(typeof name === "string" ? { "mcp-name": name } : {}),
      ...Object.fromEntries(new Headers(extraHeaders)),
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 7, method, params: { ...params, _meta: meta } }),
  })
}

function fixtureApi(): inlineApi.InlineApi {
  const unused = async (): Promise<never> => { throw new Error("Unexpected Inline operation") }
  return {
    close: vi.fn(async () => {}),
    listSpaces: vi.fn(async () => [{ id: 10n, name: "Inline", creator: true, date: 100n, isPublic: false, chatCount: 1, unreadCount: 0, lastMessageDate: null }]),
    searchPeople: unused, getEligibleChats: unused, resolveConversation: unused, getConversation: unused,
    messageContext: unused, getMessages: unused, recentMessages: unused, searchMessages: unused,
    unreadMessages: unused, createChat: unused, createSubthread: unused, forwardMessages: unused,
    uploadFile: unused, sendMessage: unused, sendMediaMessage: unused,
  }
}

describe("authenticated stateless MCP HTTP requests", () => {
  beforeEach(() => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json(introspection()))
  })
  afterEach(() => vi.restoreAllMocks())

  function app() {
    return createApp({ issuer: "http://localhost:8791", oauthInternalSharedSecret: "test-secret" })
  }

  it("serves discovery and Events through auth without creating the Inline SDK", async () => {
    const sdk = vi.spyOn(inlineApi, "createInlineApi")
    const upstream = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      if (String(input).endsWith("/oauth/mcp-events")) {
        expect(new Headers(init?.headers).get("x-inline-mcp-secret")).toBe("test-secret")
        // The backend accepts only method-specific parameters. Modern protocol
        // metadata belongs to this transport and must not cross that boundary.
        expect(JSON.parse(String(init?.body))).toEqual({ method: "events/list", token: "oauth-test-token", params: {} })
        return Response.json({ events: [{ name: "message.created", delivery: ["webhook"], inputSchema: { type: "object" }, payloadSchema: { type: "object" } }] })
      }
      return Response.json(introspection())
    })
    const server = app()
    expect((await server.fetch(modernRequest("server/discover"))).status).toBe(200)
    const response = await server.fetch(modernRequest("events/list"))
    expect(response.status).toBe(200)
    const serialized = await response.text()
    expect(JSON.parse(serialized)).toMatchObject({ result: { resultType: "complete", events: [{ name: "message.created" }] } })
    expect(serialized).not.toMatch(/oauth-test-token|test-secret|inline-token/)
    expect(upstream).toHaveBeenCalledTimes(3)
    expect(sdk).not.toHaveBeenCalled()
  })

  it("runs the Inline SDK tools and UI resource registrations through stateless HTTP", async () => {
    const inline = fixtureApi()
    const sdk = vi.spyOn(inlineApi, "createInlineApi").mockReturnValue(inline)
    const server = app()
    const listed = await server.fetch(modernRequest("tools/list"))
    expect(listed.status).toBe(200)
    const listing = await listed.json() as { result: { resultType: string; tools: Array<{ name: string }> } }
    expect(listing.result.resultType).toBe("complete")
    expect(listing.result.tools.find((tool) => tool.name === "spaces.list")).toMatchObject({
      name: "spaces.list", title: expect.any(String), inputSchema: expect.any(Object), outputSchema: expect.any(Object),
    })
    const called = await server.fetch(modernRequest("tools/call", { name: "spaces.list", arguments: {} }))
    expect(called.status).toBe(200)
    expect(await called.json()).toMatchObject({ result: { resultType: "complete", structuredContent: { items: [{ id: "10", name: "Inline" }] } } })
    expect(inline.listSpaces).toHaveBeenCalledTimes(1)
    const read = await server.fetch(modernRequest("resources/read", { uri: "ui://inline/thread-v1.html" }))
    expect(read.status).toBe(200)
    expect(await read.json()).toMatchObject({ result: { resultType: "complete", contents: [{ uri: "ui://inline/thread-v1.html", mimeType: "text/html;profile=mcp-app", text: expect.stringContaining("<html") }] } })
    expect(sdk).toHaveBeenCalledTimes(3)
    expect(sdk).toHaveBeenLastCalledWith(expect.objectContaining({ token: "1:inline-token", allowed: { allowedSpaceIds: [10n], allowDms: false, allowHomeThreads: false } }))
    expect(inline.close).toHaveBeenCalledTimes(3)
    expect(called.headers.get("mcp-session-id")).toBeNull()
  })

  it("ignores stale session IDs for modern POST and refuses modern GET/DELETE", async () => {
    const sdk = vi.spyOn(inlineApi, "createInlineApi").mockReturnValue(fixtureApi())
    const server = app()
    const response = await server.fetch(modernRequest("tools/call", { name: "account.me", arguments: {} }, { "mcp-session-id": "nonexistent" }))
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ result: { resultType: "complete", structuredContent: { user: { id: "1" }, session: { clientId: "client-1" } } } })
    for (const method of ["GET", "DELETE"]) {
      const denied = await server.fetch(new Request("http://localhost/mcp/v2", {
        method, headers: { authorization: "Bearer oauth-test-token", "mcp-protocol-version": MODERN_MCP_VERSION, "mcp-session-id": "nonexistent" },
      }))
      expect(denied.status).toBe(405)
      expect(denied.headers.get("allow")).toBe("POST")
    }
    expect(sdk).toHaveBeenCalledTimes(1)
  })

  it("re-introspects each stateless request and cannot retain a previous broader scope", async () => {
    const inline = fixtureApi()
    vi.spyOn(inlineApi, "createInlineApi").mockReturnValue(inline)
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(Response.json(introspection()))
      .mockResolvedValueOnce(Response.json(introspection("messages:read")))
    const server = app()
    const call = () => modernRequest("tools/call", { name: "spaces.list", arguments: {} })
    expect((await server.fetch(call())).status).toBe(200)
    const reduced = await server.fetch(call())
    expect(await reduced.json()).toMatchObject({ result: { resultType: "complete", isError: true, _meta: { "mcp/www_authenticate": expect.any(Array) } } })
    expect(inline.listSpaces).toHaveBeenCalledTimes(1)
    expect(inline.close).toHaveBeenCalledTimes(2)
  })

  it("does not allow discovery or event registration after revocation", async () => {
    const sdk = vi.spyOn(inlineApi, "createInlineApi")
    const upstream = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({ active: false }, { status: 401 }))
    const server = app()
    for (const method of ["server/discover", "events/subscribe"]) {
      const response = await server.fetch(modernRequest(method))
      expect(response.status).toBe(401)
      expect(response.headers.get("www-authenticate")).toContain("invalid_token")
    }
    expect(upstream).toHaveBeenCalledTimes(2)
    expect(sdk).not.toHaveBeenCalled()
  })

  it("reports missing modern headers rather than trying to initialize a session", async () => {
    const sdk = vi.spyOn(inlineApi, "createInlineApi")
    const original = modernRequest("tools/list")
    const headers = new Headers(original.headers)
    headers.delete("mcp-protocol-version")
    headers.delete("mcp-method")
    const response = await app().fetch(new Request(original, { headers }))
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: { code: -32020 } })
    expect(response.headers.get("mcp-session-id")).toBeNull()
    expect(sdk).not.toHaveBeenCalled()
  })

  it("releases the Inline SDK after dispatch failure", async () => {
    const inline = fixtureApi()
    vi.spyOn(inlineApi, "createInlineApi").mockReturnValue(inline)
    vi.spyOn(McpServer.prototype, "connect").mockRejectedValueOnce(new Error("injected setup failure"))
    const response = await app().fetch(modernRequest("tools/list"))
    expect(response.status).toBe(500)
    expect(await response.json()).toMatchObject({ error: { code: -32603 } })
    expect(inline.close).toHaveBeenCalledTimes(1)
  })

  it("uses the current OAuth bearer for event status inside a legacy session after refresh", async () => {
    const inline = fixtureApi()
    const chat: inlineApi.InlineEligibleChat = {
      chatId: 7n, title: "Review", chatTitle: "Review", kind: "space_chat", spaceId: 10n, spaceName: "Inline",
      peerUserId: null, peerDisplayName: null, peerUsername: null, archived: false, pinned: false,
      unreadCount: 0, readMaxId: null, lastMessageId: null, lastMessageDate: null,
    }
    inline.getConversation = async () => ({
      chat, description: null, emoji: null, isPublic: false, date: 100n, createdBy: 1n,
      parentChatId: null, parentMessageId: null, number: null, pinnedMessageIds: [], groupParticipantCount: 2, participants: [],
    })
    inline.recentMessages = async () => ({ chat, direction: "all", scannedCount: 0, nextOffsetId: null, messages: [] })
    vi.spyOn(inlineApi, "createInlineApi").mockReturnValue(inline)
    const eventStatus = vi.fn(async () => Response.json({ subscriptions: [{ id: "s1", name: "message.created", refreshBefore: new Date(Date.now() + 60_000).toISOString() }] }))
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      if (String(input).endsWith("/oauth/mcp-events")) {
        expect(JSON.parse(String(init?.body))).toMatchObject({ token: "refreshed-token", method: "events/status", params: { chatId: "7" } })
        return eventStatus()
      }
      return Response.json(introspection())
    })
    const server = app()
    const initialized = await server.fetch(new Request("http://localhost/mcp/v2", {
      method: "POST", headers: { authorization: "Bearer original-token", accept: "application/json, text/event-stream", "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } } }),
    }))
    expect(initialized.status).toBe(200)
    const sessionId = initialized.headers.get("mcp-session-id")!
    await initialized.text()
    const opened = await server.fetch(new Request("http://localhost/mcp/v2", {
      method: "POST", headers: { authorization: "Bearer refreshed-token", "mcp-session-id": sessionId, "mcp-protocol-version": "2025-11-25", accept: "application/json, text/event-stream", "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "conversations.open", arguments: { chatId: "7" } } }),
    }))
    expect(opened.status).toBe(200)
    expect(await opened.text()).toContain('"monitoring":{"active":true')
    expect(eventStatus).toHaveBeenCalledTimes(1)
    await server.fetch(new Request("http://localhost/mcp/v2", { method: "DELETE", headers: { authorization: "Bearer refreshed-token", "mcp-session-id": sessionId } }))
    expect(inline.close).toHaveBeenCalledTimes(1)
  })
})
