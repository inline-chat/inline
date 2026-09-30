import assert from "node:assert/strict"
import path from "node:path"
import { writeFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const { createApp } = await import(path.join(root, "packages/mcp/dist/index.js"))
let active = true
const realServer = Boolean(process.env.INLINE_E2E_BASE_URL)
const scenarios = []
const introspection = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch: () => Response.json({
    active, grant_id: "ci-grant", client_id: "ci-client", scope: "messages:read spaces:read messages:write",
    aud: "http://127.0.0.1:8791", exp: Math.floor(Date.now() / 1000) + 3600,
    inline_user_id: process.env.INLINE_E2E_BOT_ID ?? "1", space_ids: [], allow_dms: realServer, allow_home_threads: false,
    inline_token: process.env.INLINE_E2E_TOKEN ?? "1:ci-local-token",
  }),
})
let server
try {
  const app = createApp({
    issuer: "http://127.0.0.1:8791",
    inlineApiBaseUrl: process.env.INLINE_E2E_BASE_URL ?? "http://127.0.0.1:8792",
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
  let id = 2
  const request = async (method, params) => fetch(endpoint, {
    method: "POST", headers: { ...headers, "mcp-session-id": session }, signal: AbortSignal.timeout(15_000),
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, ...(params ? { params } : {}) }),
  })
  const call = async (name, args) => {
    const response = await request("tools/call", { name, arguments: args })
    assert.equal(response.status, 200)
    const text = await response.text()
    const data = text.split("\n").find((line) => line.startsWith("data: "))
    assert.ok(data, "MCP response must contain an SSE result")
    const result = JSON.parse(data.slice(6)).result
    assert.ok(result && !result.isError, `MCP ${name} must succeed`)
    return result.structuredContent
  }
  assert.equal((await call("account.me", {})).user.id, process.env.INLINE_E2E_BOT_ID ?? "1")
  scenarios.push("mcp-assembled-account-context")
  if (realServer) {
    const chatId = process.env.INLINE_E2E_CHAT_ID
    assert.match(chatId ?? "", /^[1-9]\d*$/)
    const sent = await call("messages.send", { chatId, text: "ci-mcp-persisted-message" })
    assert.equal(sent.ok, true)
    assert.match(sent.messageId, /^[1-9]\d*$/)
    const history = await call("messages.list", { chatId, limit: 20 })
    assert.ok(history.messages.some((message) => message.id === sent.messageId && message.text === "ci-mcp-persisted-message"))
    scenarios.push("mcp-real-server-send-and-history")
  }
  active = false
  assert.equal((await request("tools/list")).status, 401, "revoked grant must reject an existing MCP session")
  scenarios.push("mcp-revoked-grant-existing-session")
  active = true
  assert.equal((await fetch(endpoint, { method: "DELETE", headers: { ...headers, "mcp-session-id": session }, signal: AbortSignal.timeout(10_000) })).status, 200)
  if (process.env.INLINE_E2E_RECEIPT) await writeFile(process.env.INLINE_E2E_RECEIPT, JSON.stringify({ sourceSha: process.env.GITHUB_SHA, scenarios: scenarios.map((scenario) => ({ scenario, status: "passed" })) }, null, 2) + "\n")
  console.log(`Compiled MCP passed ${scenarios.length} scenarios with synthetic local introspection`)
} finally {
  server?.stop(true)
  introspection.stop(true)
}
