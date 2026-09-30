// Compiled artifact/HTTP contract smoke. No real Inline account or ChatGPT host.
import assert from "node:assert/strict"
import { readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const { createApp } = await import(path.join(root, "packages/mcp/dist/index.js"))
const submission = JSON.parse(await readFile(path.join(root, "packages/mcp/chatgpt-app-submission.json"), "utf8"))
const { MESSAGE_RESULTS_RESOURCE_URI: uiUri } = await import(path.join(root, "packages/mcp/dist/server/mcp/message-results-ui.js"))
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
  const secondChat = { ...chat, chatId: 8n, title: "Design", chatTitle: "Design" }
  const avatar = "https://api.inline.chat/file?id=fixture_avatar&exp=1999999999&sig=fixture"
  // Real encoder shape: non-photo originals are signed R2 URLs, not API
  // image-proxy URLs. Synthetic credentials generate a URL without networking.
  const documentUrl = new Bun.S3Client({
    accessKeyId: "c".repeat(32), secretAccessKey: "synthetic-ci-secret", bucket: "inline-fixture",
    endpoint: `https://${"a".repeat(32)}.r2.cloudflarestorage.com`, region: "auto",
  }).file("files/doc_fixture/Review.pdf").presign({ acl: "public-read", expiresIn: 3600 })
  const message = { id: 100n, chatId: 7n, fromId: 2n, message: "Compiled card text ".repeat(30), out: false, date: 1790726400n }
  const fileMessage = { id: 90n, chatId: 8n, fromId: 2n, message: "The revised design", out: false, date: 1790726300n,
    media: { media: { oneofKind: "document", document: { document: { id: 500n, fileUniqueId: "doc_fixture", fileName: "Review.pdf", mimeType: "application/pdf", size: 2048, cdnUrl: documentUrl } } } },
  }
  const authorMetadata = { senderDisplayNames: { "2": "Dena Example" }, senderAvatarUrls: { "2": avatar } }
  const resolve = (id) => {
    if (id === 7n) return chat
    if (id === 8n) return secondChat
    throw new Error("Conversation is not in the allowed context")
  }
  const inline = {
    close: async () => {},
    getEligibleChats: async () => [chat, secondChat],
    getConversation: async ({ chatId }) => ({ ...resolve(chatId), participants: [], pinnedMessageIds: [] }),
    presentationChat: async ({ chatId }) => ({ chat: resolve(chatId), lastMessage: chatId === 7n ? message : fileMessage }),
    getMessages: async ({ chatId, messageIds }) => ({ chat: resolve(chatId), ...authorMetadata,
      messages: [message, fileMessage].filter((row) => row.chatId === chatId && messageIds.includes(row.id)),
    }),
    recentMessages: async ({ chatId, offsetId }) => ({ chat: resolve(chatId), direction: "all", scannedCount: 1,
      nextOffsetId: offsetId ? null : 100n, messages: offsetId ? [] : [chatId === 7n ? message : fileMessage], ...authorMetadata,
    }),
    historyMessages: async ({ chatId, offsetId }) => ({ chat: resolve(chatId), kind: offsetId ? "older" : "latest",
      nextOffsetId: offsetId ? null : 100n, nextAfterId: null, anchorMessageId: null, firstUnreadMessageId: null, note: null,
      messages: offsetId ? [] : [chatId === 7n ? message : fileMessage], ...authorMetadata,
    }),
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
    const sent = []
    const parent = { postMessage: (value) => sent.push(value) }
    Object.defineProperty(window, "parent", { value: parent })
    Object.defineProperty(window, "fetch", { value: () => { throw new Error("card must not fetch") } })
    window.document.write(html.replace(/<script>[\s\S]+<\/script>/, ""))
    window.eval(script)
    const receive = (data) => window.dispatchEvent(new window.MessageEvent("message", { source: parent, data: { jsonrpc: "2.0", ...data } }))
    receive({ id: 1, result: { protocolVersion: "2026-01-26", hostCapabilities: { openLinks: {}, serverTools: {} }, hostContext: { theme: "light", displayMode: "inline", availableDisplayModes: ["inline", "fullscreen"] } } })
    const listed = await request("tools/call", { name: "messages.list", arguments: { chatId: "7", limit: 20 } })
    assert.deepEqual(JSON.parse(listed.content[0].text), listed.structuredContent, "data fallback retains the real result")
    const searched = await request("tools/call", { name: "messages.search", arguments: { chatId: "7", query: "blocked" } })
    assert.equal(searched.structuredContent.nextOffsetId, "99", "data search retains its history continuation")

    const sources = await request("tools/call", { name: "messages.view", arguments: {
      presentation: "sources", items: [{ chatId: "8", messageId: "90" }, { chatId: "7", messageId: "100" }, { chatId: "7", messageId: "101" }],
    } })
    assert.deepEqual(sources.structuredContent.items.map((item) => [item.chatId, item.messageId]), [["8", "90"], ["7", "100"], ["7", "101"]], "source order remains cross-chat, including unavailable selections")
    assert.equal(sources.structuredContent.items[2].status, "unavailable")
    assert.doesNotMatch(JSON.stringify([sources.structuredContent, sources.content]), /sig=fixture|X-Amz-Signature/i, "presentation credentials remain outside model-visible output")
    receive({ method: "ui/notifications/tool-result", params: sources })
    assert.match(window.document.body.textContent, /Design/)
    assert.match(window.document.body.textContent, /Contract Chat/)
    assert.match(window.document.body.textContent, /Review\.pdf/)
    assert.match(window.document.body.textContent, /Dena Example/)
    const fileOpen = [...window.document.querySelectorAll("button")].find((button) => button.textContent === "Open file")
    assert.ok(fileOpen, "real-shaped signed R2 attachment offers a file action")
    fileOpen.click()
    const openRequest = sent.findLast((event) => event.method === "ui/open-link")
    assert.equal(openRequest?.params.url, documentUrl, "original attachment opens through host without embedding R2")
    receive({ id: openRequest.id, result: {} })

    const catchUp = await request("tools/call", { name: "messages.view", arguments: {
      presentation: "catch_up", chatIds: ["7", "8"], activeChatId: "7", startAt: "latest",
    } })
    assert.equal(catchUp.structuredContent.activeChatId, "7")
    assert.equal(catchUp.structuredContent.page.nextOffsetId, "100")
    receive({ method: "ui/notifications/tool-input", params: { arguments: { presentation: "catch_up" } } })
    receive({ method: "ui/notifications/tool-result", params: catchUp })
    assert.match(window.document.body.textContent, /Compiled card text/)
    assert.equal(sent.some((event) => event.method === "tools/call"), false, "rendering alone must not make additional tool calls")

    const expand = window.document.querySelector(".expand-reader")
    assert.ok(expand, "capable host offers explicit expansion")
    expand.click()
    const displayRequest = sent.findLast((event) => event.method === "ui/request-display-mode")
    assert.equal(displayRequest?.params.mode, "fullscreen", "expansion negotiates with the host")
    receive({ id: displayRequest.id, result: { mode: "fullscreen" } })
    await Promise.resolve()
    await Promise.resolve()
    assert.ok(window.document.querySelector(".bubble"), "expanded real history uses native message bubbles")
    const photo = window.document.querySelector(".avatar img")
    assert.equal(photo?.getAttribute("src"), avatar, "compiled presentation metadata hydrates avatar")
    assert.equal(photo?.referrerPolicy, "no-referrer")
    const older = window.document.querySelector(".load-older")
    assert.ok(older, "history cursor offers an older-page action")
    older.click()
    const pageRequest = sent.findLast((event) => event.method === "tools/call")
    assert.equal(pageRequest?.params.name, "messages.view")
    assert.equal(pageRequest?.params.arguments.offsetId, "100", "navigation uses the actual server cursor")
    const olderResult = await request("tools/call", pageRequest.params)
    // MCP Apps hosts may echo app-initiated calls through the same outer
    // notifications used for model calls. This must still append one page.
    receive({ method: "ui/notifications/tool-input", params: { arguments: pageRequest.params.arguments } })
    receive({ method: "ui/notifications/tool-result", params: olderResult })
    receive({ id: pageRequest.id, result: olderResult })
    await Promise.resolve()
    await Promise.resolve()
    assert.match(window.document.body.textContent, /Compiled card text/, "empty older page preserves already read history")
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

  for (const name of ["messages.list", "messages.search", "messages.context", "messages.unread"]) {
    const tool = tools.find((tool) => tool.name === name)
    assert.equal(tool?._meta?.ui?.resourceUri, undefined, `${name} must not open a card during analysis`)
    assert.equal(tool.annotations.readOnlyHint, true)
    assert.ok(tool.outputSchema, `${name} retains structured output schema`)
  }
  const view = tools.find((tool) => tool.name === "messages.view")
  assert.equal(view?._meta?.ui?.resourceUri, uiUri, "only explicit presentation opens the message view")
  assert.equal(view?.annotations.readOnlyHint, true)
  assert.ok(view?.outputSchema, "presentation has a structured contract")
  scenarios.push("analysis-reads-are-independent-of-presentation")
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
  assert.deepEqual(csp?.connectDomains, [], "view requests use the authenticated host bridge")
  assert.deepEqual(csp?.resourceDomains, ["https://api.inline.chat"], "only Inline media may load remotely")
  scenarios.push("compiled-ui-resource-served-with-bridge-only-csp")

  // Scope-denial paths must fail before any request to the Inline server.
  scope = "spaces:read"
  for (const [method, params] of [
    ["tools/call", { name: "conversations.mentions", arguments: { query: "" } }],
    ["tools/call", { name: "messages.view", arguments: { presentation: "sources", items: [{ chatId: "123", messageId: "456" }] } }],
    ["resources/read", { uri: "inline://chat/123" }],
  ]) {
    const result = await request(method, params)
    const explicitScopeError = (result.message?.error || result.message?.result?.isError)
      && JSON.stringify(result.message).includes("messages:read")
    assert.ok(result.status === 401 || result.status === 403 || explicitScopeError,
      `${method} must deny missing messages:read`)
    assert.ok(!result.message?.result?.contents, "denial must not expose snapshot content")
  }
  scenarios.push("mentions-presentation-and-direct-resource-require-read-scope")
  active = false
  assert.equal((await request("resources/read", { uri: uiUri })).status, 401)
  scenarios.push("revoked-grant-denies-existing-session")
  assert.equal(upstreamRequests, 0, "metadata and scope-denial checks must not contact Inline")

  await checkCompiledMessageCards()
  scenarios.push("compiled-multi-chat-sources-and-catch-up-render-in-packaged-view")

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
