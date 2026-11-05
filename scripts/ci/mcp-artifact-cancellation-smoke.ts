import { pathToFileURL } from "node:url"
import { resolve } from "node:path"

// Run the packaged MCP app and SDK against a synthetic loopback upstream.
// External networking and credentials are unnecessary (CI uses --network none).
const root = resolve(process.argv[2] ?? "/app/packages/mcp")
const expectedRevision = process.argv[3]
if (expectedRevision && !/^[0-9a-f]{40}$/.test(expectedRevision)) throw new Error("Expected a full source revision")
const { createApp } = await import(pathToFileURL(`${root}/dist/server/app.js`).href)
const { MODERN_MCP_VERSION } = await import(pathToFileURL(`${root}/dist/server/mcp/modern.js`).href)
const { ClientMessage, ServerProtocolMessage, User, Method, RpcError_Code } = await import(pathToFileURL(`${root}/../protocol/dist/core.js`).href)
const issuer = "http://localhost:8791"
const abort = new AbortController()
let stalled = false
let authenticatedConnections = 0
let getMeCalls = 0
let serverFrameId = 0n
const deadline = setTimeout(() => { console.error("MCP artifact cancellation probe timed out"); process.exit(2) }, 8000)
const upstream = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch(request, server) {
    const path = new URL(request.url).pathname
    if (path === "/oauth/introspect") return Response.json({
      active: true, grant_id: "synthetic-grant", client_id: "synthetic-client", scope: "", aud: issuer,
      exp: Math.floor(Date.now() / 1000) + 60, inline_user_id: "1", space_ids: [],
      allow_dms: false, allow_home_threads: false, inline_token: "1:synthetic-sdk-token",
    })
    if (path !== "/realtime") return new Response(null, { status: 404 })
    if (!stalled) {
      stalled = true
      const disconnected = new Promise<Response>((resolve) => {
        request.signal.addEventListener("abort", () => resolve(new Response(null, { status: 499 })), { once: true })
      })
      // A real SDK HTTP upgrade is waiting; cancel only this MCP request.
      abort.abort()
      return disconnected
    }
    if (server.upgrade(request)) return
    return new Response(null, { status: 400 })
  },
  websocket: {
    message(socket, bytes) {
      if (typeof bytes === "string") throw new Error("Expected a binary SDK frame")
      const frame = ClientMessage.fromBinary(new Uint8Array(bytes))
      let body
      if (frame.body.oneofKind === "connectionInit") {
        authenticatedConnections++
        body = { oneofKind: "connectionOpen", connectionOpen: {} }
      } else if (frame.body.oneofKind === "rpcCall") {
        if (frame.body.rpcCall.method === Method.GET_ME) {
          getMeCalls++
          body = { oneofKind: "rpcResult", rpcResult: { reqMsgId: frame.id, result: {
            oneofKind: "getMe", getMe: { user: User.create({ id: 1n, firstName: "Synthetic MCP probe" }) },
          } } }
        } else body = { oneofKind: "rpcError", rpcError: { reqMsgId: frame.id, code: 400,
          errorCode: RpcError_Code.BAD_REQUEST, message: "Synthetic unsupported background RPC", retryAfterSeconds: 0 } }
      } else if (frame.body.oneofKind === "ping") body = { oneofKind: "pong", pong: { nonce: frame.body.ping.nonce } }
      if (body) socket.send(ServerProtocolMessage.toBinary({ id: ++serverFrameId, body }))
    },
  },
})
const app = createApp({ issuer, inlineApiBaseUrl: `http://127.0.0.1:${upstream.port}`,
  oauthIntrospectionUrl: `http://127.0.0.1:${upstream.port}/oauth/introspect`, oauthInternalSharedSecret: "synthetic-secret" })
const makeRequest = (signal?: AbortSignal) => new Request(`${issuer}/mcp/v2`, {
  method: "POST", signal,
  headers: { authorization: "Bearer synthetic-oauth-token", "content-type": "application/json",
    "mcp-protocol-version": MODERN_MCP_VERSION, "mcp-method": "tools/call", "mcp-name": "account.profile" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "account.profile", arguments: {}, _meta: {
    "io.modelcontextprotocol/protocolVersion": MODERN_MCP_VERSION, "io.modelcontextprotocol/clientCapabilities": {},
  } } }),
})
try {
  const cancelled = await app.fetch(makeRequest(abort.signal))
  const cancelledBody = await cancelled.json()
  if (!stalled || !abort.signal.aborted || cancelled.status !== 500 || cancelledBody.error?.code !== -32603) throw new Error("Expected bounded MCP interruption response")
  const fresh = await app.fetch(makeRequest())
  const freshBody = await fresh.json()
  if (fresh.status !== 200 || freshBody.result?.isError || freshBody.result?.structuredContent?.id !== "1" || authenticatedConnections !== 1 || getMeCalls !== 1) {
    throw new Error("A fresh MCP request did not reconnect and read its synthetic profile")
  }
  const health = await app.fetch(new Request(`${issuer}/health`))
  const healthBody = await health.json()
  if (health.status !== 200 || healthBody.ok !== true || (expectedRevision && healthBody.revision !== expectedRevision)) {
    throw new Error("MCP health or artifact revision failed after cancellation")
  }
  console.log(JSON.stringify({ runtime: Bun.version, abortedRequestStatus: cancelled.status, freshRequestStatus: fresh.status,
    authenticatedConnections, getMeCalls, health: true, revision: healthBody.revision,
    scope: "isolated synthetic loopback; no production credentials or requests" }))
} finally {
  await upstream.stop(true)
  clearTimeout(deadline)
}
