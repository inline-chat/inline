import { describe, expect, it, vi } from "vitest"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { InlineSdkAuthenticationError, ProtocolClientError } from "@inline-chat/realtime-sdk"
import {
  ConnectionError_Reason,
  Method,
  RpcCall,
  RpcError,
  RpcError_Code,
  RpcResult,
} from "@inline-chat/protocol/core"
import { createInlineApi } from "./inline-api"
import {
  INLINE_RPC_AUTH_REASON_HEADER,
  INLINE_RPC_CONTENT_TYPE,
  createHttpRpcInvoker,
} from "./rpc-invoker"
import { createInlineMcpServer } from "../mcp/server"
import type { McpGrant } from "../mcp/grant"

const protobuf = (bytes: Uint8Array, init: { status?: number; headers?: Record<string, string> } = {}) =>
  new Response(bytes as Uint8Array<ArrayBuffer>, {
    status: init.status ?? 200,
    headers: { "content-type": INLINE_RPC_CONTENT_TYPE, ...init.headers },
  })

const ok = (result: RpcResult["result"]) => protobuf(RpcResult.toBinary(RpcResult.create({ reqMsgId: 0n, result })))

const rpcError = (error: Omit<RpcError, "reqMsgId">, status = error.code, headers?: Record<string, string>) =>
  protobuf(RpcError.toBinary({ reqMsgId: 0n, ...error }), { status, headers })

/** A fake Inline endpoint: decodes each RpcCall and answers from `respond`. */
function stubServer(respond: (call: RpcCall, request: Request) => Response | Promise<Response>) {
  const calls: Array<{ call: RpcCall; request: Request }> = []
  const fetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
    const request = new Request(url, init)
    const call = RpcCall.fromBinary(new Uint8Array(await request.clone().arrayBuffer()))
    calls.push({ call, request })
    return await respond(call, request)
  })
  return { fetch: fetch as unknown as typeof globalThis.fetch, calls }
}

const getMe = { oneofKind: "getMe", getMe: {} } as const

describe("createHttpRpcInvoker", () => {
  it("posts a protobuf RpcCall with the bearer and decodes the RpcResult", async () => {
    const server = stubServer(() => ok({ oneofKind: "getMe", getMe: { user: { id: 42n, firstName: "Ada" } } }))
    const rpc = createHttpRpcInvoker({ baseUrl: "https://api.inline.test/", token: "42:secret", fetch: server.fetch })

    await expect(rpc.invoke(Method.GET_ME, getMe)).resolves.toEqual({ oneofKind: "getMe", getMe: { user: { id: 42n, firstName: "Ada" } } })

    const [{ call, request }] = server.calls
    expect(request.url).toBe("https://api.inline.test/v1/rpc")
    expect(request.method).toBe("POST")
    expect(request.headers.get("authorization")).toBe("Bearer 42:secret")
    expect(request.headers.get("content-type")).toBe(INLINE_RPC_CONTENT_TYPE)
    expect(call).toEqual(RpcCall.create({ method: Method.GET_ME, input: getMe }))
  })

  it("rejects a result of the wrong kind like the SDK", async () => {
    const server = stubServer(() => ok({ oneofKind: "getChats", getChats: { dialogs: [], chats: [], spaces: [], users: [], messages: [], folders: [] } }))
    const rpc = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: server.fetch })
    await expect(rpc.invoke(Method.GET_ME, getMe)).rejects.toThrow("rpc result mismatch: method GET_ME expects getMe")
  })

  it("maps an RpcError to the SDK's ProtocolClientError", async () => {
    const server = stubServer(() => rpcError({ errorCode: RpcError_Code.RATE_LIMIT, message: "Too many requests: rate limited, retry after 7 s", code: 429, retryAfterSeconds: 7 }))
    const rpc = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: server.fetch })
    const error = await rpc.invoke(Method.GET_ME, getMe).catch((e: unknown) => e)
    // What the realtime ProtocolClient builds from the same RpcError frame.
    const expected = new ProtocolClientError("rpc-error", { code: 429, message: "Too many requests: rate limited, retry after 7 s", retryAfterSeconds: 7 })
    expect(error).toBeInstanceOf(ProtocolClientError)
    expect(error).toMatchObject({ name: expected.name, code: expected.code, rpcCode: expected.rpcCode, message: expected.message, retryAfterSeconds: 7 })
  })

  it.each([
    ["INVALID_AUTH", ConnectionError_Reason.INVALID_AUTH],
    ["SESSION_REVOKED", ConnectionError_Reason.SESSION_REVOKED],
    ["UNAUTHORIZED", ConnectionError_Reason.UNAUTHORIZED],
  ] as const)("maps a %s bearer rejection to the SDK authentication error", async (code, reason) => {
    const server = stubServer(() => rpcError(
      { errorCode: RpcError_Code.UNAUTHENTICATED, message: "Unauthenticated", code: 401, retryAfterSeconds: 0 },
      401,
      { [INLINE_RPC_AUTH_REASON_HEADER]: code },
    ))
    const rpc = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: server.fetch })
    const error = await rpc.invoke(Method.GET_ME, getMe).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(InlineSdkAuthenticationError)
    expect(error).toMatchObject({ code, reason, message: `Inline authentication failed: ${code}` })
  })

  it("keeps a handler UNAUTHENTICATED error as an RPC error", async () => {
    const server = stubServer(() => rpcError({ errorCode: RpcError_Code.UNAUTHENTICATED, message: "Unauthenticated", code: 401, retryAfterSeconds: 0 }))
    const rpc = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: server.fetch })
    await expect(rpc.invoke(Method.GET_ME, getMe)).rejects.toMatchObject({ code: "rpc-error", rpcCode: 401 })
  })

  it("times out reads as retryable and writes as an uncertain commit", async () => {
    const hang = vi.fn((_url: string | URL | Request, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))
    }))
    const rpc = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: hang as unknown as typeof fetch, timeoutMs: 5 })

    await expect(rpc.invoke(Method.GET_ME, getMe)).rejects.toMatchObject({ code: "timeout" })
    await expect(rpc.invoke(Method.CREATE_CHAT, { oneofKind: "createChat", createChat: { title: "x", isPublic: false, participants: [] } }))
      .rejects.toMatchObject({ code: "commit-outcome-unknown", message: "RPC timed out after dispatch" })
    // A send with an idempotency key is replay-safe, as in the SDK.
    await expect(rpc.invoke(Method.SEND_MESSAGE, { oneofKind: "sendMessage", sendMessage: { randomId: 9n } }))
      .rejects.toMatchObject({ code: "timeout" })
  })

  it("propagates caller cancellation to the request", async () => {
    let requestSignal: AbortSignal | undefined
    const hang = vi.fn((_url: string | URL | Request, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      requestSignal = init?.signal ?? undefined
      init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))
    }))
    const rpc = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: hang as unknown as typeof fetch })
    const controller = new AbortController()
    const reason = new Error("tool cancelled")
    const pending = rpc.invoke(Method.GET_ME, getMe, { signal: controller.signal })
    await vi.waitFor(() => expect(requestSignal).toBeDefined())
    controller.abort(reason)
    await expect(pending).rejects.toBe(reason)
    expect(requestSignal?.aborted).toBe(true)

    await expect(rpc.invoke(Method.GET_ME, getMe, { signal: controller.signal })).rejects.toBe(reason)
    expect(hang).toHaveBeenCalledTimes(1)
  })

  it("classifies transport failures and foreign responses by replay safety", async () => {
    const offline = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: (async () => { throw new TypeError("fetch failed") }) as unknown as typeof fetch })
    await expect(offline.invoke(Method.GET_ME, getMe)).rejects.toMatchObject({ code: "not-connected" })
    await expect(offline.invoke(Method.FORWARD_MESSAGES, { oneofKind: "forwardMessages", forwardMessages: { messageIds: [1n], shareForwardHeader: true } }))
      .rejects.toMatchObject({ code: "commit-outcome-unknown" })

    const gateway = createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "t", fetch: (async () => new Response("<html>bad gateway</html>", { status: 502, headers: { "content-type": "text/html" } })) as unknown as typeof fetch })
    await expect(gateway.invoke(Method.GET_ME, getMe)).rejects.toMatchObject({ code: "not-connected", message: "Inline RPC transport failed: HTTP 502" })
  })
})

describe("inline-api over the HTTP invoker", () => {
  const grant: McpGrant = { id: "g1", clientId: "c1", inlineUserId: 42n, scope: "messages:read messages:write", spaceIds: [10n], allowDms: true, allowHomeThreads: false }

  const accountServer = (failAuth = false) => stubServer((call) => {
    if (failAuth) {
      return rpcError({ errorCode: RpcError_Code.UNAUTHENTICATED, message: "Unauthenticated", code: 401, retryAfterSeconds: 0 }, 401, { [INLINE_RPC_AUTH_REASON_HEADER]: "SESSION_REVOKED" })
    }
    switch (call.input.oneofKind) {
      case "getMe": return ok({ oneofKind: "getMe", getMe: { user: { id: 42n, firstName: "Ada", lastName: "Lovelace", email: "ada@example.test" } } })
      case "sendMessage": return ok({
        oneofKind: "sendMessage",
        sendMessage: { updates: [{ update: { oneofKind: "updateMessageId", updateMessageId: { messageId: 501n, randomId: call.input.sendMessage.randomId ?? 1n } } }], addedUserIds: [], unaddedUserIds: [] },
      })
      default: return rpcError({ errorCode: RpcError_Code.BAD_REQUEST, message: `Unsupported RPC method: ${call.method}`, code: 400, retryAfterSeconds: 0 })
    }
  })

  it("reads the profile and sends a message with an idempotency key", async () => {
    const server = accountServer()
    const api = createInlineApi({
      baseUrl: "https://api.inline.test",
      token: "42:secret",
      allowed: { allowedSpaceIds: [], allowDms: true },
      rpc: createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "42:secret", fetch: server.fetch }),
    })
    try {
      await expect(api.getProfile()).resolves.toEqual({ id: 42n, name: "Ada Lovelace", email: "ada@example.test" })
      await expect(api.sendMessage({ userId: 7n, text: "**hi**", sendMode: "silent", parseMarkdown: true })).resolves.toEqual({ messageId: 501n, spaceId: null })
      const send = server.calls[1]!.call
      expect(send.method).toBe(Method.SEND_MESSAGE)
      if (send.input.oneofKind !== "sendMessage") throw new Error("expected sendMessage")
      expect(send.input.sendMessage).toMatchObject({ message: "**hi**", parseMarkdown: true, peerId: { type: { oneofKind: "user", user: { userId: 7n } } } })
      expect(send.input.sendMessage.randomId).not.toBe(0n)
    } finally { await api.close() }
  })

  async function callProfileTool(failAuth: boolean) {
    const server = accountServer(failAuth)
    const inline = createInlineApi({
      baseUrl: "https://api.inline.test",
      token: "42:secret",
      allowed: { allowedSpaceIds: grant.spaceIds, allowDms: grant.allowDms, allowHomeThreads: grant.allowHomeThreads },
      rpc: createHttpRpcInvoker({ baseUrl: "https://api.inline.test", token: "42:secret", fetch: server.fetch }),
    })
    const mcp = createInlineMcpServer({ grant, inline })
    const sent: JSONRPCMessage[] = []
    const transport: Transport = { async start() {}, async close() {}, async send(message) { sent.push(message) } }
    const authInfo: AuthInfo = {
      token: "mcp-token", clientId: grant.clientId, scopes: [], expiresAt: Math.floor(Date.now() / 1000) + 3600,
      extra: { grantId: grant.id, inlineUserId: grant.inlineUserId.toString() },
    }
    await mcp.connect(transport)
    const deliver = (message: unknown) => transport.onmessage?.(message as JSONRPCMessage, { authInfo } as never)
    deliver({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } } })
    await vi.waitFor(() => expect(sent.some((m) => (m as { id?: number }).id === 1)).toBe(true))
    deliver({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })
    deliver({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "account.profile", arguments: {} } })
    await vi.waitFor(() => expect(sent.some((m) => (m as { id?: number }).id === 2)).toBe(true))
    const response = sent.find((m) => (m as { id?: number }).id === 2) as { result: Record<string, any> }
    await mcp.close()
    await inline.close()
    return response.result
  }

  it("runs a tool end to end through the HTTP endpoint", async () => {
    const result = await callProfileTool(false)
    expect(result.isError).toBe(false)
    expect(result.structuredContent).toEqual({ id: "42", name: "Ada Lovelace", email: "ada@example.test" })
  })

  it("keeps the tool's revoked-session behavior", async () => {
    const result = await callProfileTool(true)
    expect(result.isError).toBe(true)
    expect(result._meta["mcp/www_authenticate"][0]).toContain('error="invalid_token"')
    expect(result._meta.inline).toEqual({ accessDenied: true })
  })
})
