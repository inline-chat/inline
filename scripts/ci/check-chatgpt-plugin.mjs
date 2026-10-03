// Compiled artifact/HTTP contract smoke. No real Inline account or ChatGPT host.
import assert from "node:assert/strict"
import { readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const requireMcp = createRequire(path.join(root, "packages/mcp/package.json"))
const { default: Ajv2020 } = await import(requireMcp.resolve("ajv/dist/2020.js"))
const { default: Ajv } = await import(requireMcp.resolve("ajv"))
const { default: addFormats } = await import(requireMcp.resolve("ajv-formats"))
const protocolSchema = JSON.parse(await readFile(path.join(root, "scripts/ci/fixtures/mcp-2026-07-28/schema.json"), "utf8"))
const protocolValidator = new Ajv2020({ strict: false, allErrors: true })
const toolValidator = new Ajv({ strict: false, allErrors: true })
addFormats(protocolValidator)
addFormats(toolValidator)
const resultTypes = {
  "server/discover": "DiscoverResult", "tools/list": "ListToolsResult",
  "resources/list": "ListResourcesResult", "resources/templates/list": "ListResourceTemplatesResult",
  "resources/read": "ReadResourceResult", "tools/call": "CallToolResult",
}
const schemaValidators = new Map()
const validator = (name) => {
  if (!schemaValidators.has(name)) schemaValidators.set(name, protocolValidator.compile({
    $ref: `#/$defs/${name}`, $defs: protocolSchema.$defs,
  }))
  return schemaValidators.get(name)
}
const assertSchema = (name, value, context) => {
  const validate = validator(name)
  assert.ok(validate(value), `${context}: ${JSON.stringify(validate.errors)}`)
}
const validatedResponses = []
function validateModernResponse(method, message) {
  const name = resultTypes[method]
  if (!name) return // Events use a separate draft, not the core protocol schema.
  assertSchema(`${name}Response`, message, `${method} response envelope`)
  // ReadResourceResultResponse also accepts an extensible InputRequiredResult.
  // Validate the announced complete branch explicitly, not just that loose union.
  assertSchema(name, message.result, `${method} complete result`)
  validatedResponses.push({ method, message: structuredClone(message) })
}
const { createApp } = await import(path.join(root, "packages/mcp/dist/index.js"))
const submission = JSON.parse(await readFile(path.join(root, "packages/mcp/chatgpt-app-submission.json"), "utf8"))
const uiUri = "ui://inline/message-results-v1.html"
const threadUiUri = "ui://inline/thread-v2.html"
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
const eventRequests = []
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
  fetch: async (request) => {
    if (new URL(request.url).pathname === "/oauth/mcp-events") {
      assert.equal(request.headers.get("x-inline-mcp-secret"), "synthetic-ci-secret")
      const body = await request.json()
      assert.equal(body.token, "mcp_at_chatgpt_ci")
      assert.deepEqual(Object.keys(body).sort(), ["method", "params", "token"])
      assert.ok(!("_meta" in body.params), "protocol metadata must stop at the MCP proxy")
      eventRequests.push(body)
      if (body.method === "events/list") return Response.json({ events: [{
        name: "message.created", delivery: ["webhook"],
        inputSchema: { type: "object", properties: { chatId: { type: "string" } }, required: ["chatId"] },
      }] })
      if (body.method === "events/subscribe") return Response.json({ id: "ci-subscription", cursor: "ci-cursor", truncated: false, refreshBefore: new Date(Date.now() + 300_000).toISOString() })
      if (body.method === "events/unsubscribe") return Response.json({})
      throw new Error("Unexpected compiled-smoke internal event method")
    }
    return Response.json({
    active, grant_id: "chatgpt-ci-grant", client_id: "chatgpt-ci-client", scope,
    aud: "http://127.0.0.1:8791", exp: Math.floor(Date.now() / 1000) + 3600,
    inline_user_id: "1", space_ids: [], allow_dms: false, allow_home_threads: false,
    inline_token: "1:synthetic-ci-token",
    })
  },
})

try {
  const app = createApp({
    issuer: "http://127.0.0.1:8791",
    inlineApiBaseUrl: `http://127.0.0.1:${upstream.port}`,
    oauthIssuer: "http://127.0.0.1:8791",
    oauthProxyBaseUrl: `http://127.0.0.1:${introspection.port}`,
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

  const open = tools.find((tool) => tool.name === "conversations.open")
  const ask = tools.find((tool) => tool.name === "conversations.ask")
  assert.equal(open?._meta?.ui?.resourceUri, threadUiUri)
  assert.deepEqual(open?._meta?.["openai/ui"]?.entrypoints, [{ type: "thread" }, { type: "global" }])
  assert.equal(ask?._meta?.ui?.resourceUri, threadUiUri)
  assert.equal(ask?.annotations.idempotentHint, false)
  for (const name of ["conversations.ask", "conversations.create", "messages.send", "messages.send_media", "messages.send_batch"]) {
    assert.equal(tools.find((tool) => tool.name === name)?.annotations.openWorldHint, true,
      `${name} communicates with independently controlled recipients, even in a private thread`)
  }
  const emptyPicker = await success("tools/call", { name: "conversations.open", arguments: {} })
  assert.equal(emptyPicker.structuredContent.chat, null)
  assert.deepEqual(emptyPicker.structuredContent.messages, [])
  assert.equal(emptyPicker.structuredContent.capabilities.canSend, false)
  scenarios.push("minimal-thread-entrypoints-open-without-workspace-catalog")

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

  const thread = await success("resources/read", { uri: threadUiUri })
  assert.equal(thread.contents[0].mimeType, "text/html;profile=mcp-app")
  assert.match(thread.contents[0].text, /ui\/initialize/)
  assert.match(thread.contents[0].text, /conversations\.open/)
  assert.match(thread.contents[0].text, /messages\.send/)
  assert.deepEqual(thread.contents[0]._meta.ui.csp.connectDomains, [])
  assert.deepEqual(thread.contents[0]._meta.ui.csp.resourceDomains, ["https://api.inline.chat"])
  scenarios.push("compiled-react-thread-resource-and-exact-asset-csp")

  const modernVersion = "2026-07-28"
  const modernRequest = async (method, params = {}) => {
    const id = ++requestId
    const response = await fetch(endpoint, {
      method: "POST", signal: AbortSignal.timeout(10_000),
      headers: { ...headers, "mcp-protocol-version": modernVersion, "mcp-method": method,
        // A cached legacy session must never select the legacy lane.
        "mcp-session-id": session,
        ...(method === "tools/call" ? { "mcp-name": params.name } : method === "resources/read" ? { "mcp-name": params.uri } : {}),
      },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params: { ...params, _meta: {
        "io.modelcontextprotocol/protocolVersion": modernVersion,
        "io.modelcontextprotocol/clientCapabilities": {},
      } } }),
    })
    assert.equal(response.status, 200, `${method} modern HTTP status`)
    assert.equal(response.headers.get("mcp-session-id"), null)
    const message = await response.json()
    assert.equal(message.id, id)
    assert.equal(message.result?.resultType, "complete")
    assert.ok(!message.error && !message.result.isError, `${method} modern result`)
    assert.doesNotMatch(JSON.stringify(message), /mcp_at_chatgpt_ci|synthetic-ci-secret|synthetic-ci-token/, "protocol replies must not leak credentials")
    validateModernResponse(method, message)
    return message.result
  }
  const discovered = await modernRequest("server/discover")
  assert.deepEqual(discovered.capabilities.events, {})
  assert.ok(discovered.supportedVersions.includes(modernVersion))
  const modernTools = (await modernRequest("tools/list")).tools
  assert.deepEqual(modernTools.map((tool) => tool.name).sort(), tools.map((tool) => tool.name).sort())
  for (const tool of modernTools) {
    toolValidator.compile(tool.inputSchema)
    if (tool.outputSchema) toolValidator.compile(tool.outputSchema)
  }
  const modernResources = (await modernRequest("resources/list")).resources
  await modernRequest("resources/templates/list")
  for (const resource of modernResources) {
    const result = await modernRequest("resources/read", { uri: resource.uri })
    assert.ok(result.contents.some((content) => content.uri === resource.uri), "every advertised resource is readable")
  }
  for (const name of ["account.me", "conversations.open"]) {
    const result = await modernRequest("tools/call", { name, arguments: {} })
    const tool = modernTools.find((tool) => tool.name === name)
    assert.ok(tool?.outputSchema, `${name} output schema`)
    const validateOutput = toolValidator.compile(tool.outputSchema)
    assert.ok(validateOutput(result.structuredContent), `${name}: ${JSON.stringify(validateOutput.errors)}`)
  }
  scenarios.push("all-modern-catalogs-and-advertised-resources-match-official-schema")

  // Negative controls reproduce the production defect and prove nested schema
  // validation remains active. These must fail without relying on HTTP status.
  for (const { method, message } of validatedResponses) {
    const name = resultTypes[method]
    const validateResult = validator(name)
    for (const field of ["resultType", ...(method === "tools/call" ? [] : ["ttlMs", "cacheScope"])]) {
      const malformed = structuredClone(message.result)
      delete malformed[field]
      assert.equal(validateResult(malformed), false, `${method} must reject missing ${field}`)
    }
    const missingId = structuredClone(message)
    delete missingId.id
    assert.equal(validator(`${name}Response`)(missingId), false, `${method} must reject missing response ID`)
  }
  const badTool = structuredClone(modernTools)
  delete badTool[0].inputSchema
  assert.equal(validator("ListToolsResult")({ resultType: "complete", ttlMs: 0, cacheScope: "private", tools: badTool }), false)
  assert.equal(validator("ReadResourceResult")({ resultType: "complete", ttlMs: 0, cacheScope: "private", contents: [{ uri: threadUiUri, text: 42 }] }), false)
  scenarios.push("official-schema-rejects-old-cache-defect-and-malformed-nested-payloads")

  for (const [label, method, params, metadata, extraHeaders, expectedStatus, expectedCode] of [
    ["missing client capabilities", "tools/list", {}, { "io.modelcontextprotocol/clientCapabilities": null }, {}, 400, -32602],
    ["version mismatch", "tools/list", {}, {}, { "mcp-protocol-version": "2026-07-27" }, 400, -32020],
    ["unsupported version", "tools/list", {}, { "io.modelcontextprotocol/protocolVersion": "2026-07-27" }, { "mcp-protocol-version": "2026-07-27" }, 400, -32022],
    ["resource name mismatch", "resources/read", { uri: threadUiUri }, {}, { "mcp-name": "ui://wrong/resource.html" }, 400, -32020],
    ["unknown tool", "tools/call", { name: "not-a-tool", arguments: {} }, {}, { "mcp-name": "not-a-tool" }, 400, -32602],
    ["unknown method", "not-a-method", {}, {}, {}, 404, -32601],
  ]) {
    const id = ++requestId
    const response = await fetch(endpoint, {
      method: "POST", signal: AbortSignal.timeout(10_000),
      headers: { ...headers, "mcp-protocol-version": modernVersion, "mcp-method": method, ...extraHeaders },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params: { ...params, _meta: {
        "io.modelcontextprotocol/protocolVersion": modernVersion,
        "io.modelcontextprotocol/clientCapabilities": {}, ...metadata,
      } } }),
    })
    const message = await response.json()
    assert.equal(response.status, expectedStatus, label)
    assert.equal(message.id, id, label)
    assert.equal(message.error?.code, expectedCode, label)
    assertSchema("JSONRPCErrorResponse", message, label)
  }
  scenarios.push("modern-http-rejects-invalid-metadata-headers-versions-and-methods")
  const listedEvents = await modernRequest("events/list")
  assert.equal(listedEvents.events[0].name, "message.created")
  const selector = { name: "message.created", arguments: { chatId: "7", excludeSelf: true } }
  const delivery = { mode: "webhook", url: "https://callbacks.example.com/inline", secret: "whsec_Y2ktdGVzdC1zaWduaW5nLWtleS13aXRoLWVub3VnaC1ieXRlcw==" }
  const subscribed = await modernRequest("events/subscribe", { ...selector, delivery, cursor: "ci-cursor", ttlMs: 300_000 })
  assert.equal(subscribed.id, "ci-subscription")
  assert.equal(subscribed.truncated, false)
  await modernRequest("events/unsubscribe", { ...selector, delivery: { mode: delivery.mode, url: delivery.url } })
  assert.deepEqual(eventRequests.map((value) => value.method), ["events/list", "events/subscribe", "events/unsubscribe"])
  assert.deepEqual(eventRequests[1].params.arguments, selector.arguments)
  assert.equal((await modernRequest("tools/call", { name: "conversations.open", arguments: {} })).structuredContent.chat, null)
  scenarios.push("modern-discovery-events-and-ui-preserve-legacy-session-compatibility")

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
  scope = "messages:read spaces:read"
  const deniedAsk = await request("tools/call", { name: "conversations.ask", arguments: { title: "CI consultation", question: "Approved fixture question", participantUserIds: ["2"] } })
  assert.ok(deniedAsk.message?.result?.isError)
  assert.match(JSON.stringify(deniedAsk.message), /messages:write/)
  assert.equal(eventRequests.length, 3, "write denial must precede Events preflight")
  scenarios.push("consultation-write-scope-denied-before-side-effects")
  active = false
  assert.equal((await request("resources/read", { uri: uiUri })).status, 401)
  const revokedModern = await fetch(endpoint, {
    method: "POST", signal: AbortSignal.timeout(10_000),
    headers: { ...headers, "mcp-protocol-version": modernVersion, "mcp-method": "resources/read", "mcp-name": threadUiUri },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++requestId, method: "resources/read", params: { uri: threadUiUri, _meta: {
      "io.modelcontextprotocol/protocolVersion": modernVersion, "io.modelcontextprotocol/clientCapabilities": {},
    } } }),
  })
  assert.equal(revokedModern.status, 401)
  assert.match(revokedModern.headers.get("www-authenticate") ?? "", /invalid_token/)
  scenarios.push("revoked-grant-denies-existing-session")
  assert.equal(upstreamRequests, 0, "metadata and scope-denial checks must not contact Inline")

  await checkCompiledMessageCards()
  scenarios.push("compiled-list-and-search-results-render-in-packaged-card")

  const receipt = {
    sourceSha: process.env.GITHUB_SHA ?? null,
    evidence: "compiled MCP HTTP contract with synthetic local OAuth; not ChatGPT host acceptance",
    protocolSchema: { version: "2026-07-28", upstreamCommit: "271ecc9accafdd9b83a3c869fa67c22953b2af80", validatedResponses: validatedResponses.length },
    scenarios: scenarios.map((scenario) => ({ scenario, status: "passed" })),
  }
  if (process.argv[2]) await writeFile(process.argv[2], `${JSON.stringify(receipt, null, 2)}\n`)
  console.log(`ChatGPT plugin contract: ${scenarios.length} scenarios passed. Real host acceptance remains separate.`)
} finally {
  appServer?.stop(true)
  introspection.stop(true)
  upstream.stop(true)
}
