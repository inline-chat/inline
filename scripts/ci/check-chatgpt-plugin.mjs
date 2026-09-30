// Compiled artifact/HTTP contract smoke. No real Inline account or ChatGPT host.
import assert from "node:assert/strict"
import { readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const { createApp } = await import(path.join(root, "packages/mcp/dist/index.js"))
const submission = JSON.parse(await readFile(path.join(root, "packages/mcp/chatgpt-app-submission.json"), "utf8"))
const uiUri = "ui://inline/message-results-v1.html"
const scenarios = []

// Use compiled tool handlers and their packaged HTML together. Domain fixtures
// replace the upstream account; the wire result is produced by the real server.
async function checkCompiledMessageCards() {
  const { createInlineMcpServer } = await import(path.join(root, "packages/mcp/dist/server/mcp/server.js"))
  const requireMcp = createRequire(path.join(root, "packages/mcp/package.json"))
  const { Window } = await import(requireMcp.resolve("happy-dom"))
  const chat = {
    chatId: 7n, title: "Contract Chat", chatTitle: "Contract Chat", kind: "space_chat", spaceId: 10n, spaceName: "Inline",
    peerUserId: null, peerDisplayName: null, peerUsername: null, archived: false, pinned: false, unreadCount: 0,
    readMaxId: null, lastMessageId: 100n, lastMessageDate: 1790726400n,
  }
  const message = { id: 100n, chatId: 7n, fromId: 2n, message: "Compiled card text ".repeat(30), out: false, date: 1790726400n }
  const inline = {
    close: async () => {},
    recentMessages: async () => ({ chat, direction: "all", scannedCount: 1, nextOffsetId: 100n, messages: [message], senderDisplayNames: { "2": "Dena Example" }, senderAvatarUrls: { "2": "https://api.inline.chat/file?id=fixture_avatar&exp=1999999999&sig=fixture" } }),
    searchMessages: async ({ query }) => ({ chat, query, content: "all", mode: "search", nextOffsetId: 99n, messages: [], senderDisplayNames: {} }),
  }
  const server = createInlineMcpServer({
    grant: { id: "card-contract", clientId: "card-client", inlineUserId: 1n, scope: "messages:read", spaceIds: [10n], allowDms: false, allowHomeThreads: false },
    inline, contractVersion: "submission-v2",
  })
  const pending = new Map()
  const transport = {
    start: async () => {}, close: async () => {},
    send: async (message) => { if (typeof message.id === "number") pending.get(message.id)?.(message) },
  }
  const authInfo = { token: "synthetic-card-token", clientId: "card-client", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }
  let requestId = 0
  const request = async (method, params) => {
    const id = ++requestId
    const response = new Promise((resolve) => pending.set(id, resolve))
    transport.onmessage({ jsonrpc: "2.0", id, method, params }, { authInfo })
    let timeout
    const deadline = new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error(`${method} compiled card contract timed out`)), 5_000) })
    let message
    try { message = await Promise.race([response, deadline]) }
    finally { clearTimeout(timeout); pending.delete(id) }
    assert.ok(message.result && !message.error && !message.result.isError, `${method} compiled card contract must succeed`)
    return message.result
  }
  let window
  try {
    await server.connect(transport)
    await request("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "compiled-card-contract", version: "1" } })
    transport.onmessage({ jsonrpc: "2.0", method: "notifications/initialized" }, { authInfo })
    const { contents } = await request("resources/read", { uri: uiUri })
    const html = contents[0].text
    const script = html.match(/<script>([\s\S]+)<\/script>/)?.[1]
    assert.ok(script, "compiled card must include its script")
    window = new Window({ url: "https://mcp.inline.chat", settings: { enableJavaScriptEvaluation: true } })
    const parent = { postMessage: () => {} }
    Object.defineProperty(window, "parent", { value: parent })
    Object.defineProperty(window, "fetch", { value: () => { throw new Error("card must not fetch") } })
    window.document.write(html.replace(/<script>[\s\S]+<\/script>/, ""))
    window.eval(script)
    const receive = (data) => window.dispatchEvent(new window.MessageEvent("message", { source: parent, data: { jsonrpc: "2.0", ...data } }))
    receive({ id: 1, result: { protocolVersion: "2026-01-26", hostContext: { theme: "light" } } })
    const listed = await request("tools/call", { name: "messages.list", arguments: { chatId: "7", limit: 20 } })
    assert.equal(listed.structuredContent.senderUserId, undefined, "published list shape has no sender filter")
    assert.deepEqual(JSON.parse(listed.content[0].text), listed.structuredContent, "text fallback retains the real result")
    receive({ method: "ui/notifications/tool-result", params: listed })
    assert.equal(window.document.querySelectorAll("li").length, 1, "real list result must render")
    assert.equal(window.document.querySelector(".sender")?.textContent, "Dena Example")
    assert.ok(window.document.querySelector(".incoming .bubble"), "incoming messages use a native bubble")
    const photo = window.document.querySelector(".avatar img")
    assert.equal(photo?.getAttribute("src"), listed._meta.inline.senderAvatarUrls["2"])
    assert.equal(photo?.referrerPolicy, "no-referrer")
    assert.doesNotMatch(JSON.stringify([listed.structuredContent, listed.content]), /sig=fixture/, "signed avatars stay out of model-visible content")
    photo.dispatchEvent(new window.Event("error"))
    assert.equal(photo.hidden, true, "unavailable photo reveals the native initials fallback")
    assert.equal(window.document.querySelector(".avatar-initial")?.textContent, "D")
    const disclosure = window.document.querySelector("button")
    assert.ok(disclosure, "long returned text must have local disclosure")
    disclosure.click()
    assert.equal(window.document.querySelector(".message-text")?.textContent, message.message)
    const searched = await request("tools/call", { name: "messages.search", arguments: { chatId: "7", query: "blocked" } })
    assert.equal(searched.structuredContent.senderUserId, undefined, "published search shape has no sender filter")
    assert.equal(searched.structuredContent.nextOffsetId, "99")
    receive({ method: "ui/notifications/tool-result", params: searched })
    assert.equal(window.document.querySelectorAll("li").length, 0, "search replaces previous rows")
    assert.match(window.document.querySelector("footer")?.textContent ?? "", /More matches may exist\. Try a narrower search\./)
    assert.doesNotMatch(window.document.body.textContent, /No messages matched/)
  } finally {
    await window?.happyDOM.close()
    await server.close()
  }
}
let active = true
let scope = "messages:read spaces:read"
let appServer
let upstreamRequests = 0
const upstream = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch: () => {
    upstreamRequests += 1
    return new Response("This metadata-only check must not call Inline", { status: 503 })
  },
})
const introspection = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: () => Response.json({
    active, grant_id: "chatgpt-ci-grant", client_id: "chatgpt-ci-client", scope,
    aud: "http://127.0.0.1:8791", exp: Math.floor(Date.now() / 1000) + 3600,
    inline_user_id: "1", space_ids: [], allow_dms: false, allow_home_threads: false,
    inline_token: "1:synthetic-ci-token",
  }),
})

try {
  const app = createApp({
    issuer: "http://127.0.0.1:8791",
    inlineApiBaseUrl: `http://127.0.0.1:${upstream.port}`,
    oauthIssuer: "http://127.0.0.1:8791",
    oauthProxyBaseUrl: "http://127.0.0.1:8791",
    oauthIntrospectionUrl: `http://127.0.0.1:${introspection.port}/introspect`,
    oauthInternalSharedSecret: "synthetic-ci-secret",
  })
  appServer = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch })
  const endpoint = `http://127.0.0.1:${appServer.port}/mcp/v2`
  const headers = {
    authorization: "Bearer mcp_at_chatgpt_ci",
    accept: "application/json, text/event-stream",
    "content-type": "application/json",
  }
  let session
  let requestId = 0
  const request = async (method, params, authenticated = true) => {
    const id = ++requestId
    const requestHeaders = { ...headers, ...(session ? { "mcp-session-id": session } : {}) }
    if (!authenticated) delete requestHeaders.authorization
    const response = await fetch(endpoint, {
      method: "POST", headers: requestHeaders, signal: AbortSignal.timeout(10_000),
      body: JSON.stringify({ jsonrpc: "2.0", id, method, ...(params ? { params } : {}) }),
    })
    session = response.headers.get("mcp-session-id") ?? session
    const body = await response.text()
    const messages = response.headers.get("content-type")?.includes("text/event-stream")
      ? body.split(/\r?\n\r?\n/).flatMap((event) => {
          const data = event.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n")
          return data ? [JSON.parse(data)] : []
        })
      : body ? [JSON.parse(body)] : []
    return { status: response.status, message: messages.find((message) => message.id === id) }
  }
  const success = async (method, params) => {
    const { status, message } = await request(method, params)
    assert.equal(status, 200, `${method} HTTP status`)
    assert.ok(message?.result && !message.error && !message.result.isError, `${method} must return a successful MCP result`)
    return message.result
  }

  assert.equal((await request("resources/read", { uri: uiUri }, false)).status, 401)
  scenarios.push("anonymous-resource-read-denied")
  await success("initialize", {
    protocolVersion: "2025-11-25", capabilities: {},
    clientInfo: { name: "inline-chatgpt-contract-ci", version: "1" },
  })
  assert.ok(session, "HTTP initialization must create a session")
  const initialized = await fetch(endpoint, {
    method: "POST", headers: { ...headers, "mcp-session-id": session }, signal: AbortSignal.timeout(10_000),
    body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
  })
  assert.equal(initialized.status, 202, "client initialization notification must be accepted")
  const { tools } = await success("tools/list")
  assert.ok(Array.isArray(tools))
  const mentions = tools.find((tool) => tool.name === "conversations.mentions")
  assert.ok(mentions, "mention search must be advertised")
  assert.ok(mentions._meta?.["openai/extensions"]?.["mentions/search"], "mention search extension metadata")
  assert.deepEqual(mentions._meta?.ui?.visibility, ["app"])
  assert.ok(mentions._meta?.securitySchemes?.some((scheme) => scheme.type === "oauth2" && scheme.scopes.includes("messages:read")))
  scenarios.push("mention-search-advertised-with-read-scope")

  for (const name of ["messages.list", "messages.search"]) {
    const tool = tools.find((tool) => tool.name === name)
    assert.equal(tool?._meta?.ui?.resourceUri, uiUri, `${name} UI resource`)
    assert.equal(tool.annotations.readOnlyHint, true)
    assert.ok(tool.outputSchema, `${name} retains structured output schema`)
  }
  for (const tool of tools) {
    const declared = submission.tools[tool.name]
    assert.ok(declared, `submission annotations missing for ${tool.name}`)
    for (const key of ["readOnlyHint", "openWorldHint", "destructiveHint"]) {
      assert.equal(declared.annotations[key], tool.annotations[key], `${tool.name} ${key} submission drift`)
    }
    for (const key of ["read_only_justification", "open_world_justification", "destructive_justification"]) {
      assert.ok(declared.justifications[key]?.trim(), `${tool.name} ${key} must explain its annotation`)
    }
  }
  assert.deepEqual(Object.keys(submission.tools).sort(), tools.map((tool) => tool.name).sort(), "submission tool inventory must match compiled server")
  scenarios.push("submission-annotations-match-compiled-tools")

  const { resourceTemplates } = await success("resources/templates/list")
  assert.ok(resourceTemplates.some((resource) => resource.uriTemplate === "inline://chat/{chatId}"))
  const { contents } = await success("resources/read", { uri: uiUri })
  assert.equal(contents.length, 1)
  assert.equal(contents[0].uri, uiUri)
  assert.equal(contents[0].mimeType, "text/html;profile=mcp-app")
  assert.match(contents[0].text, /<html[\s>]/i)
  assert.match(contents[0].text, /ui\/initialize/)
  assert.match(contents[0].text, /ui\/notifications\/tool-result/)
  const csp = contents[0]._meta?.ui?.csp
  assert.deepEqual(csp?.connectDomains, [], "passive cards must not request network connections")
  assert.deepEqual(csp?.resourceDomains, ["https://api.inline.chat"], "only Inline profile images may load remotely")
  scenarios.push("compiled-ui-resource-served-with-passive-csp")

  // Scope-denial paths must fail before any request to the Inline server.
  scope = "spaces:read"
  for (const [method, params] of [
    ["tools/call", { name: "conversations.mentions", arguments: { query: "" } }],
    ["resources/read", { uri: "inline://chat/123" }],
  ]) {
    const result = await request(method, params)
    const explicitScopeError = (result.message?.error || result.message?.result?.isError)
      && JSON.stringify(result.message).includes("messages:read")
    assert.ok(result.status === 401 || result.status === 403 || explicitScopeError,
      `${method} must deny missing messages:read`)
    assert.ok(!result.message?.result?.contents, "denial must not expose snapshot content")
  }
  scenarios.push("mention-search-and-direct-resource-require-read-scope")
  active = false
  assert.equal((await request("resources/read", { uri: uiUri })).status, 401)
  scenarios.push("revoked-grant-denies-existing-session")
  assert.equal(upstreamRequests, 0, "metadata and scope-denial checks must not contact Inline")

  await checkCompiledMessageCards()
  scenarios.push("compiled-list-and-search-results-render-in-packaged-card")

  const receipt = {
    sourceSha: process.env.GITHUB_SHA ?? null,
    evidence: "compiled MCP HTTP contract with synthetic local OAuth; not ChatGPT host acceptance",
    scenarios: scenarios.map((scenario) => ({ scenario, status: "passed" })),
  }
  if (process.argv[2]) await writeFile(process.argv[2], `${JSON.stringify(receipt, null, 2)}\n`)
  console.log(`ChatGPT plugin contract: ${scenarios.length} scenarios passed. Real host acceptance remains separate.`)
} finally {
  appServer?.stop(true)
  introspection.stop(true)
  upstream.stop(true)
}
