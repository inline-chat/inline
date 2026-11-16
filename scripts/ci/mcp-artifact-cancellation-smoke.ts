import { pathToFileURL } from "node:url"
import { resolve } from "node:path"

// Run the packaged MCP app and SDK against a synthetic loopback upstream.
// External networking and credentials are unnecessary (CI uses --network none).
const root = resolve(process.argv[2] ?? "/app/packages/mcp")
const expectedRevision = process.argv[3]
if (expectedRevision && !/^[0-9a-f]{40}$/.test(expectedRevision)) throw new Error("Expected a full source revision")
const { createApp } = await import(pathToFileURL(`${root}/dist/server/app.js`).href)
const { MODERN_MCP_VERSION } = await import(pathToFileURL(`${root}/dist/server/mcp/modern.js`).href)
const { RpcCall, RpcResult, RpcError, RpcError_Code, Method, User } = await import(pathToFileURL(`${root}/../protocol/dist/core.js`).href)
const issuer = "http://localhost:8791"
const protobuf = { "content-type": "application/x-protobuf" }
const abort = new AbortController()
let stalled = false
let stalledUpstreamAborted!: () => void
const upstreamCancelled = new Promise<void>((resolve) => { stalledUpstreamAborted = resolve })
let authenticatedRpcCalls = 0
let getMeCalls = 0
let realtimeRequests = 0
const deadline = setTimeout(() => { console.error("MCP artifact cancellation probe timed out"); process.exit(2) }, 8000)
// MCP tools call Inline over the stateless HTTP RPC endpoint (POST /v1/rpc);
// only native uploads open a realtime socket, and this probe never uploads.
const upstream = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/oauth/introspect") return Response.json({
      active: true, grant_id: "synthetic-grant", client_id: "synthetic-client", scope: "", aud: issuer,
      exp: Math.floor(Date.now() / 1000) + 60, inline_user_id: "1", space_ids: [],
      allow_dms: false, allow_home_threads: false, inline_token: "1:synthetic-sdk-token",
    })
    if (path === "/realtime") { realtimeRequests++; return new Response(null, { status: 404 }) }
    if (path !== "/v1/rpc" || request.method !== "POST") return new Response(null, { status: 404 })
    if (request.headers.get("authorization") !== "Bearer 1:synthetic-sdk-token") return new Response(null, { status: 401 })
    const call = RpcCall.fromBinary(new Uint8Array(await request.arrayBuffer()))
    authenticatedRpcCalls++
    if (!stalled) {
      stalled = true
      const disconnected = new Promise<Response>((resolve) => {
        request.signal.addEventListener("abort", () => {
          stalledUpstreamAborted()
          resolve(new Response(null, { status: 499 }))
        }, { once: true })
      })
      // A real MCP RPC is in flight upstream; cancel only this MCP request.
      abort.abort()
      return disconnected
    }
    if (call.method === Method.GET_ME) {
      getMeCalls++
      return new Response(RpcResult.toBinary({ reqMsgId: 0n, result: {
        oneofKind: "getMe", getMe: { user: User.create({ id: 1n, firstName: "Synthetic MCP probe" }) },
      } }), { headers: protobuf })
    }
    return new Response(RpcError.toBinary({ reqMsgId: 0n, code: 400, errorCode: RpcError_Code.BAD_REQUEST,
      message: "Synthetic unsupported RPC", retryAfterSeconds: 0 }), { status: 400, headers: protobuf })
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
  // The interrupted request must also release its upstream RPC, not leave it
  // running until the invoker's own deadline.
  const released = await Promise.race([upstreamCancelled.then(() => true), Bun.sleep(2000).then(() => false)])
  if (!released) throw new Error("The interrupted MCP request left its upstream RPC running")
  const fresh = await app.fetch(makeRequest())
  const freshBody = await fresh.json()
  if (fresh.status !== 200 || freshBody.result?.isError || freshBody.result?.structuredContent?.id !== "1" || authenticatedRpcCalls !== 2 || getMeCalls !== 1 || realtimeRequests !== 0) {
    throw new Error("A fresh MCP request did not reconnect and read its synthetic profile")
  }
  const health = await app.fetch(new Request(`${issuer}/health`))
  const healthBody = await health.json()
  if (health.status !== 200 || healthBody.ok !== true || (expectedRevision && healthBody.revision !== expectedRevision)) {
    throw new Error("MCP health or artifact revision failed after cancellation")
  }
  console.log(JSON.stringify({ runtime: Bun.version, abortedRequestStatus: cancelled.status, freshRequestStatus: fresh.status,
    upstreamRpcReleased: true, authenticatedRpcCalls, getMeCalls, realtimeRequests, health: true, revision: healthBody.revision,
    scope: "isolated synthetic loopback; no production credentials or requests" }))
} finally {
  await upstream.stop(true)
  clearTimeout(deadline)
}
