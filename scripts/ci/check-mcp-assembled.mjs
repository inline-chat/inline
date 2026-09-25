import assert from "node:assert/strict"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const { createApp } = await import(path.join(root, "packages/mcp/dist/index.js"))
const introspection = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch: () => Response.json({
    active: true, grant_id: "ci-grant", client_id: "ci-client", scope: "messages:read spaces:read messages:write",
    aud: "http://127.0.0.1:8791", exp: Math.floor(Date.now() / 1000) + 3600,
    inline_user_id: "1", space_ids: [], allow_dms: false, allow_home_threads: false,
    inline_token: "1:ci-local-token",
  }),
})
let server
try {
  const app = createApp({
    issuer: "http://127.0.0.1:8791",
    inlineApiBaseUrl: "http://127.0.0.1:8792",
    oauthIssuer: "http://127.0.0.1:8791",
    oauthProxyBaseUrl: "http://127.0.0.1:8791",
    oauthIntrospectionUrl: `http://127.0.0.1:${introspection.port}/introspect`,
    oauthInternalSharedSecret: "ci-local-secret",
  })
  server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch })
  const endpoint = `http://127.0.0.1:${server.port}/mcp/v2`
  const unauthorized = await fetch(endpoint, { method: "POST", signal: AbortSignal.timeout(10_000) })
  assert.equal(unauthorized.status, 401)
  const headers = {
    authorization: "Bearer mcp_at_ci",
    accept: "application/json, text/event-stream",
    "content-type": "application/json",
  }
  const initialized = await fetch(endpoint, {
    method: "POST", headers, signal: AbortSignal.timeout(10_000),
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "inline-ci", version: "1" },
    } }),
  })
  assert.equal(initialized.status, 200)
  assert.match(initialized.headers.get("content-type") ?? "", /text\/event-stream/)
  const session = initialized.headers.get("mcp-session-id")
  assert.ok(session)
  assert.match(await initialized.text(), /"version":"0\.2\.0"/)
  const tools = await fetch(endpoint, {
    method: "POST", headers: { ...headers, "mcp-session-id": session }, signal: AbortSignal.timeout(10_000),
    body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }),
  })
  assert.equal(tools.status, 200)
  assert.match(await tools.text(), /tools/)
  console.log("Compiled MCP app initialized and listed tools with synthetic local introspection")
} finally {
  server?.stop(true)
  introspection.stop(true)
}
