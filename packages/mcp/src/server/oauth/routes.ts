import type { McpConfig } from "../config"
import type { AuthRequest, Store } from "../store"
import { badRequest, html, notFound, withJson } from "../http/response"

export const OAuth = {
  async handle(req: Request, url: URL, config: McpConfig, store: Store): Promise<Response | null> {
    // Best-effort TTL cleanup.
    store.cleanupExpired(Date.now())

    if (url.pathname === "/.well-known/oauth-authorization-server") {
      return withJson({
        issuer: config.issuer,
        authorization_endpoint: `${config.issuer}/oauth/authorize`,
        token_endpoint: `${config.issuer}/oauth/token`,
        registration_endpoint: `${config.issuer}/oauth/register`,
        revocation_endpoint: `${config.issuer}/oauth/revoke`,
        scopes_supported: ["offline_access", "messages:read", "messages:write", "spaces:read"],
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        token_endpoint_auth_methods_supported: ["none"],
        code_challenge_methods_supported: ["S256"],
      })
    }

    if (url.pathname === "/.well-known/oauth-protected-resource") {
      // RFC 9728 (recommended by MCP auth spec). Keep minimal.
      return withJson({
        resource: config.issuer,
        authorization_servers: [config.issuer],
        scopes_supported: ["offline_access", "messages:read", "messages:write", "spaces:read"],
        bearer_methods_supported: ["header"],
      })
    }

    if (url.pathname === "/oauth/register" || url.pathname === "/register") {
      if (req.method !== "POST") return notFound()
      return await handleRegister(req, store)
    }

    if (url.pathname === "/oauth/authorize" || url.pathname === "/authorize") {
      if (req.method !== "GET") return notFound()
      return await handleAuthorizeGet(url, config, store)
    }
    if (url.pathname === "/oauth/authorize/send-email-code") {
      if (req.method !== "POST") return notFound()
      return await handleAuthorizeSendEmailCode(req, config, store)
    }
    if (url.pathname === "/oauth/authorize/verify-email-code") {
      if (req.method !== "POST") return notFound()
      return await handleAuthorizeVerifyEmailCode(req, config, store)
    }
    if (url.pathname === "/oauth/authorize/consent") {
      if (req.method !== "POST") return notFound()
      return await handleAuthorizeConsent(req, config, store)
    }
    if (url.pathname === "/oauth/token" || url.pathname === "/token") {
      if (req.method !== "POST") return notFound()
      return await handleToken(req, config, store)
    }
    if (url.pathname === "/oauth/revoke" || url.pathname === "/revoke") {
      if (req.method !== "POST") return notFound()
      return await handleRevoke(req, store)
    }

    return null
  },
}

async function handleRegister(req: Request, store: Store): Promise<Response> {
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return badRequest("invalid_json")
  }

  if (!body || typeof body !== "object") return badRequest("invalid_json")
  const redirectUris = (body as any).redirect_uris as unknown
  if (!Array.isArray(redirectUris) || redirectUris.length === 0) return badRequest("missing_redirect_uris")
  if (!redirectUris.every((v) => typeof v === "string")) return badRequest("invalid_redirect_uris")

  const normalized = redirectUris.map((u) => u.trim())
  if (normalized.some((u) => u.length === 0)) return badRequest("invalid_redirect_uris")
  for (const uri of normalized) {
    if (!isAllowedRedirectUri(uri)) return badRequest("invalid_redirect_uri")
  }

  const clientNameValue = (body as any).client_name as unknown
  const clientName = typeof clientNameValue === "string" && clientNameValue.trim() ? clientNameValue.trim() : null

  const nowMs = Date.now()
  const client = store.createClient({ redirectUris: normalized, clientName, nowMs })

  return withJson(
    {
      client_id: client.clientId,
      client_id_issued_at: Math.floor(nowMs / 1000),
      redirect_uris: client.redirectUris,
      client_name: client.clientName ?? undefined,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
    },
    {
      status: 201,
      headers: {
        "cache-control": "no-store",
      },
    },
  )
}

function isAllowedRedirectUri(uri: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(uri)
  } catch {
    return false
  }

  if (parsed.protocol === "https:") return true
  if (parsed.protocol !== "http:") return false

  const host = parsed.hostname
  return host === "localhost" || host === "127.0.0.1" || host === "[::1]"
}

const AUTH_REQUEST_TTL_MS = 15 * 60_000
const AUTH_CODE_TTL_MS = 5 * 60_000
const ACCESS_TOKEN_TTL_MS = 60 * 60_000
const REFRESH_TOKEN_TTL_MS = 30 * 24 * 60 * 60_000

type ParsedParamsResult = { ok: true; params: Record<string, string> } | { ok: false; response: Response }

function normalizeRateLimitKeyPart(value: string): string {
  const normalized = value.trim().toLowerCase()
  if (!normalized) return "unknown"
  return normalized.slice(0, 200)
}

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase()
}

function resolveClientIp(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for")
  if (forwarded) {
    const first = forwarded.split(",", 1)[0]?.trim()
    if (first) return normalizeRateLimitKeyPart(first)
  }

  const realIp = req.headers.get("x-real-ip")
  if (realIp?.trim()) return normalizeRateLimitKeyPart(realIp)

  const cfConnectingIp = req.headers.get("cf-connecting-ip")
  if (cfConnectingIp?.trim()) return normalizeRateLimitKeyPart(cfConnectingIp)

  return "unknown"
}

function consumeRateLimit(
  store: Store,
  input: { key: string; nowMs: number; rule: { max: number; windowMs: number } },
): { allowed: boolean; retryAfterSeconds: number } {
  return store.consumeRateLimit({
    key: input.key,
    nowMs: input.nowMs,
    max: input.rule.max,
    windowMs: input.rule.windowMs,
  })
}

function rateLimitedJson(retryAfterSeconds: number, description: string): Response {
  return withJson(
    { error: "rate_limited", error_description: description },
    {
      status: 429,
      headers: {
        "retry-after": String(retryAfterSeconds),
      },
    },
  )
}

function rateLimitedHtml(retryAfterSeconds: number, description: string): Response {
  return html(
    429,
    renderPage("Too many requests", `<div class="error">${escapeHtml(description)}</div>`),
    {
      headers: {
        "retry-after": String(retryAfterSeconds),
      },
    },
  )
}

async function parseRequestParams(req: Request): Promise<ParsedParamsResult> {
  const contentType = req.headers.get("content-type") ?? ""
  const params: Record<string, string> = {}

  if (contentType.includes("application/json")) {
    let body: unknown
    try {
      body = await req.json()
    } catch {
      return { ok: false, response: badRequest("invalid_json") }
    }
    if (!body || typeof body !== "object") return { ok: false, response: badRequest("invalid_json") }
    for (const [k, v] of Object.entries(body)) {
      if (typeof v === "string") params[k] = v
    }
    return { ok: true, params }
  }

  if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
    const form = await req.formData()
    for (const [k, v] of form.entries()) {
      params[k] = String(v)
    }
    return { ok: true, params }
  }

  // Missing/unknown content-type. Treat as empty params.
  return { ok: true, params }
}

function authRequestCookieName(config: McpConfig): string {
  return `${config.cookiePrefix}_ar`
}

function getCookie(req: Request, name: string): string | null {
  const header = req.headers.get("cookie")
  if (!header) return null
  const parts = header.split(";")
  for (const part of parts) {
    const idx = part.indexOf("=")
    if (idx === -1) continue
    const k = part.slice(0, idx).trim()
    if (k !== name) continue
    return part.slice(idx + 1).trim()
  }
  return null
}

function setCookieHeader(config: McpConfig, name: string, value: string, opts: { maxAgeSeconds?: number } = {}): string {
  const secure = config.issuer.startsWith("https://")
  const maxAge = opts.maxAgeSeconds != null ? `; Max-Age=${opts.maxAgeSeconds}` : ""
  const flags = `${secure ? "; Secure" : ""}; HttpOnly; SameSite=Lax; Path=/oauth`
  return `${name}=${value}${maxAge}${flags}`
}

function renderPage(title: string, body: string): string {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(title)}</title>
  <style>
    body { font-family: ui-sans-serif, system-ui; margin: 40px; color: #111; }
    .card { max-width: 520px; border: 1px solid #e5e5e5; border-radius: 12px; padding: 20px; }
    label { display: block; margin-top: 12px; font-weight: 600; }
    input { width: 100%; padding: 10px; margin-top: 6px; border-radius: 8px; border: 1px solid #ccc; }
    button { margin-top: 16px; padding: 10px 14px; border-radius: 10px; border: 1px solid #111; background: #111; color: #fff; cursor: pointer; }
    .muted { color: #666; font-size: 13px; margin-top: 10px; }
    .error { color: #b00020; margin-top: 10px; }
    .spaces { margin-top: 12px; }
    .spaces label { font-weight: 500; display: flex; gap: 10px; align-items: center; }
    .spaces input { width: auto; margin: 0; }
    code { background: #f5f5f5; padding: 2px 6px; border-radius: 6px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>${escapeHtml(title)}</h1>
    ${body}
  </div>
</body>
</html>`
}

function escapeHtml(input: string): string {
  return input.replace(/[&<>"']/g, (c) => {
    switch (c) {
      case "&":
        return "&amp;"
      case "<":
        return "&lt;"
      case ">":
        return "&gt;"
      case '"':
        return "&quot;"
      case "'":
        return "&#39;"
    }
    return c
  })
}

function base64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest("SHA-256", data)
  const bytes = new Uint8Array(digest)
  let out = ""
  for (const b of bytes) out += b.toString(16).padStart(2, "0")
  return out
}

async function sha256Base64Url(input: string): Promise<string> {
  const data = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest("SHA-256", data)
  return base64Url(new Uint8Array(digest))
}

function constantTimeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let out = 0
  for (let i = 0; i < a.length; i++) {
    out |= a.charCodeAt(i) ^ b.charCodeAt(i)
  }
  return out === 0
}

async function importAesKeyFromConfig(config: McpConfig): Promise<CryptoKey> {
  if (!config.tokenEncryptionKeyB64) throw new Error("missing MCP_TOKEN_ENCRYPTION_KEY_B64")
  const raw = Buffer.from(config.tokenEncryptionKeyB64, "base64")
  if (raw.byteLength !== 32) throw new Error("MCP_TOKEN_ENCRYPTION_KEY_B64 must be 32 bytes (base64)")
  return await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"])
}

async function encryptInlineToken(config: McpConfig, plaintext: string): Promise<string> {
  const key = await importAesKeyFromConfig(config)
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const pt = new TextEncoder().encode(plaintext)
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, pt)
  return `v1.${base64Url(iv)}.${base64Url(new Uint8Array(ct))}`
}

async function decryptInlineToken(config: McpConfig, enc: string): Promise<string> {
  const [v, ivB64, ctB64] = enc.split(".")
  if (v !== "v1" || !ivB64 || !ctB64) throw new Error("invalid encrypted token")
  const key = await importAesKeyFromConfig(config)
  const iv = base64UrlToBytes(ivB64)
  const ct = base64UrlToBytes(ctB64)
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ct)
  return new TextDecoder().decode(pt)
}

function base64UrlToBytes(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)
  return new Uint8Array(Buffer.from(padded, "base64"))
}

function parseInlineUserIdFromToken(token: string): bigint {
  const prefix = token.split(":")[0]
  if (!prefix) throw new Error("invalid token")
  return BigInt(prefix)
}

function normalizeScopes(scope: string): string {
  const parts = scope
    .split(/\s+/)
    .map((s) => s.trim())
    .filter(Boolean)
  const allowed = new Set(["offline_access", "messages:read", "messages:write", "spaces:read"])
  const uniq: string[] = []
  for (const p of parts) {
    if (!allowed.has(p)) continue
    if (!uniq.includes(p)) uniq.push(p)
  }
  // Default to read scopes if none requested.
  if (uniq.length === 0) return "messages:read spaces:read"
  return uniq.join(" ")
}

async function inlineApiCall<T>(
  config: McpConfig,
  path: string,
  body: unknown,
  token?: string,
): Promise<{ ok: true; json: T } | { ok: false; status: number }> {
  const res = await fetch(`${config.inlineApiBaseUrl}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  })
  if (!res.ok) return { ok: false, status: res.status }
  const json = (await res.json()) as T
  return { ok: true, json }
}

function getAuthRequestFromCookie(req: Request, config: McpConfig, store: Store): AuthRequest | null {
  const id = getCookie(req, authRequestCookieName(config))
  if (!id) return null
  return store.getAuthRequest(id, Date.now())
}

async function handleAuthorizeGet(url: URL, config: McpConfig, store: Store): Promise<Response> {
  const responseType = url.searchParams.get("response_type")
  const clientId = url.searchParams.get("client_id")
  const redirectUri = url.searchParams.get("redirect_uri")
  const state = url.searchParams.get("state")
  const scopeRaw = url.searchParams.get("scope") ?? ""
  const codeChallenge = url.searchParams.get("code_challenge")
  const codeChallengeMethod = url.searchParams.get("code_challenge_method") ?? "S256"

  if (responseType !== "code") return badRequest("invalid_response_type")
  if (!clientId || !redirectUri || !state || !codeChallenge) return badRequest("missing_params")
  if (codeChallengeMethod !== "S256") return badRequest("invalid_code_challenge_method")

  const client = store.getClient(clientId)
  if (!client) return badRequest("invalid_client")
  if (!client.redirectUris.includes(redirectUri)) return badRequest("invalid_redirect_uri")

  const nowMs = Date.now()
  const id = crypto.randomUUID()
  const csrfToken = base64Url(crypto.getRandomValues(new Uint8Array(32)))
  const deviceId = crypto.randomUUID()

  store.createAuthRequest({
    id,
    clientId,
    redirectUri,
    state,
    scope: normalizeScopes(scopeRaw),
    codeChallenge,
    csrfToken,
    deviceId,
    nowMs,
    expiresAtMs: nowMs + AUTH_REQUEST_TTL_MS,
  })

  const cookie = setCookieHeader(config, authRequestCookieName(config), id)
  const page = renderPage(
    "Sign in to Inline",
    `
<form method="post" action="/oauth/authorize/send-email-code">
  <input type="hidden" name="csrf" value="${escapeHtml(csrfToken)}" />
  <label>Email</label>
  <input name="email" type="email" autocomplete="email" required />
  <button type="submit">Send code</button>
  <div class="muted">You will receive a 6-digit code.</div>
</form>`,
  )
  return html(200, page, { headers: { "set-cookie": cookie, "cache-control": "no-store" } })
}

async function handleAuthorizeSendEmailCode(req: Request, config: McpConfig, store: Store): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(req)
  const endpointRate = consumeRateLimit(store, {
    key: `endpoint:send-email-code:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.sendEmailCode,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many email-code requests. Try again shortly.")
  }

  const ar = getAuthRequestFromCookie(req, config, store)
  if (!ar) return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))

  const form = await req.formData()
  const csrf = String(form.get("csrf") ?? "")
  const email = normalizeEmail(String(form.get("email") ?? ""))

  if (!constantTimeEq(csrf, ar.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }
  if (!email || !email.includes("@")) {
    return html(400, renderPage("Error", `<div class="error">Invalid email.</div>`))
  }

  const emailHash = await sha256Hex(email)
  const perEmail = consumeRateLimit(store, {
    key: `abuse:send-email:email:${emailHash}`,
    nowMs,
    rule: config.emailAbuseRateLimits.sendPerEmail,
  })
  if (!perEmail.allowed) {
    return rateLimitedHtml(perEmail.retryAfterSeconds, "Too many attempts for this email. Try again later.")
  }

  const perContext = consumeRateLimit(store, {
    key: `abuse:send-email:context:${emailHash}:${normalizeRateLimitKeyPart(ar.clientId)}:${normalizeRateLimitKeyPart(ar.deviceId)}:${clientIp}`,
    nowMs,
    rule: config.emailAbuseRateLimits.sendPerContext,
  })
  if (!perContext.allowed) {
    return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context. Try again later.")
  }

  const sendRes = await inlineApiCall<{ existingUser: boolean }>(config, "/v1/sendEmailCode", { email })
  if (!sendRes.ok) {
    return html(502, renderPage("Error", `<div class="error">Failed to send code.</div>`))
  }

  store.setAuthRequestEmail(ar.id, email)

  const page = renderPage(
    "Enter code",
    `
<form method="post" action="/oauth/authorize/verify-email-code">
  <input type="hidden" name="csrf" value="${escapeHtml(ar.csrfToken)}" />
  <label>Code</label>
  <input name="code" inputmode="numeric" autocomplete="one-time-code" required />
  <button type="submit">Verify</button>
  <div class="muted">Sent to <code>${escapeHtml(email)}</code>.</div>
</form>`,
  )
  return html(200, page, { headers: { "cache-control": "no-store" } })
}

async function handleAuthorizeVerifyEmailCode(req: Request, config: McpConfig, store: Store): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(req)
  const endpointRate = consumeRateLimit(store, {
    key: `endpoint:verify-email-code:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.verifyEmailCode,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many verification attempts. Try again shortly.")
  }

  const ar = getAuthRequestFromCookie(req, config, store)
  if (!ar) return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  if (!ar.email) return html(400, renderPage("Error", `<div class="error">Missing email. Start over.</div>`))

  const form = await req.formData()
  const csrf = String(form.get("csrf") ?? "")
  const code = String(form.get("code") ?? "").trim()
  if (!constantTimeEq(csrf, ar.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }
  if (!code || code.length < 6) {
    return html(400, renderPage("Error", `<div class="error">Invalid code.</div>`))
  }

  const normalizedEmail = normalizeEmail(ar.email)
  const emailHash = await sha256Hex(normalizedEmail)
  const perEmail = consumeRateLimit(store, {
    key: `abuse:verify-email:email:${emailHash}`,
    nowMs,
    rule: config.emailAbuseRateLimits.verifyPerEmail,
  })
  if (!perEmail.allowed) {
    return rateLimitedHtml(perEmail.retryAfterSeconds, "Too many verification attempts for this email. Try again later.")
  }

  const perContext = consumeRateLimit(store, {
    key: `abuse:verify-email:context:${emailHash}:${normalizeRateLimitKeyPart(ar.clientId)}:${normalizeRateLimitKeyPart(ar.deviceId)}:${clientIp}`,
    nowMs,
    rule: config.emailAbuseRateLimits.verifyPerContext,
  })
  if (!perContext.allowed) {
    return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context. Try again later.")
  }

  const verifyRes = await inlineApiCall<{ token: string; userId: number }>(
    config,
    "/v1/verifyEmailCode",
    {
      email: ar.email,
      code,
      deviceId: ar.deviceId,
      clientType: "web",
      deviceName: "ChatGPT MCP",
    },
  )
  if (!verifyRes.ok) return html(401, renderPage("Error", `<div class="error">Code verification failed.</div>`))

  const token = verifyRes.json.token
  const inlineUserId = parseInlineUserIdFromToken(token)
  store.setAuthRequestInlineUserId(ar.id, inlineUserId)

  let tokenEnc: string
  try {
    tokenEnc = await encryptInlineToken(config, token)
  } catch (e) {
    return html(500, renderPage("Error", `<div class="error">Server misconfigured.</div>`))
  }
  store.setAuthRequestInlineTokenEnc(ar.id, tokenEnc)

  const spacesRes = await inlineApiCall<{ spaces: Array<{ id: number; title?: string; name?: string }> }>(
    config,
    "/v1/getSpaces",
    {},
    token,
  )
  if (!spacesRes.ok) return html(502, renderPage("Error", `<div class="error">Failed to load spaces.</div>`))

  const spaces = spacesRes.json.spaces ?? []
  const list = spaces
    .map((s) => {
      const label = s.title ?? s.name ?? `Space ${s.id}`
      return `<label><input type="checkbox" name="space_id" value="${String(s.id)}" /> ${escapeHtml(label)}</label>`
    })
    .join("")

  const page = renderPage(
    "Choose spaces",
    `
<form method="post" action="/oauth/authorize/consent">
  <input type="hidden" name="csrf" value="${escapeHtml(ar.csrfToken)}" />
  <div class="muted">Requested scopes: <code>${escapeHtml(ar.scope)}</code></div>
  <div class="spaces">${list}</div>
  <button type="submit">Allow</button>
  <div class="muted">You can revoke access by disconnecting the connector in ChatGPT.</div>
</form>`,
  )
  return html(200, page, { headers: { "cache-control": "no-store" } })
}

async function handleAuthorizeConsent(req: Request, config: McpConfig, store: Store): Promise<Response> {
  const ar = getAuthRequestFromCookie(req, config, store)
  if (!ar) return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  if (!ar.inlineTokenEnc || !ar.inlineUserId) return html(400, renderPage("Error", `<div class="error">Not signed in.</div>`))

  const form = await req.formData()
  const csrf = String(form.get("csrf") ?? "")
  if (!constantTimeEq(csrf, ar.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }
  const selected = form.getAll("space_id").map((v) => String(v))
  if (selected.length === 0) {
    return html(400, renderPage("Error", `<div class="error">Select at least one space.</div>`))
  }

  let token: string
  try {
    token = await decryptInlineToken(config, ar.inlineTokenEnc)
  } catch {
    return html(400, renderPage("Error", `<div class="error">Invalid session.</div>`))
  }

  const spacesRes = await inlineApiCall<{ spaces: Array<{ id: number }> }>(config, "/v1/getSpaces", {}, token)
  if (!spacesRes.ok) return html(502, renderPage("Error", `<div class="error">Failed to load spaces.</div>`))

  const allowedIds = new Set(spacesRes.json.spaces.map((s) => String(s.id)))
  const chosen = selected.filter((id) => allowedIds.has(id)).map((id) => BigInt(id))
  if (chosen.length === 0) {
    return html(400, renderPage("Error", `<div class="error">Invalid space selection.</div>`))
  }

  const nowMs = Date.now()
  const grantId = crypto.randomUUID()
  store.createGrant({
    id: grantId,
    clientId: ar.clientId,
    inlineUserId: ar.inlineUserId,
    scope: ar.scope,
    spaceIds: chosen,
    inlineTokenEnc: ar.inlineTokenEnc,
    nowMs,
  })

  const code = base64Url(crypto.getRandomValues(new Uint8Array(32)))
  store.createAuthCode({
    code,
    grantId,
    clientId: ar.clientId,
    redirectUri: ar.redirectUri,
    codeChallenge: ar.codeChallenge,
    nowMs,
    expiresAtMs: nowMs + AUTH_CODE_TTL_MS,
  })

  store.deleteAuthRequest(ar.id)

  const cookie = setCookieHeader(config, authRequestCookieName(config), "", { maxAgeSeconds: 0 })
  const redirect = new URL(ar.redirectUri)
  redirect.searchParams.set("code", code)
  redirect.searchParams.set("state", ar.state)
  return new Response(null, { status: 302, headers: { location: redirect.toString(), "set-cookie": cookie } })
}

async function handleToken(req: Request, config: McpConfig, store: Store): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(req)
  const endpointRate = consumeRateLimit(store, {
    key: `endpoint:token:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.token,
  })
  if (!endpointRate.allowed) {
    return rateLimitedJson(endpointRate.retryAfterSeconds, "Too many token requests.")
  }

  const parsed = await parseRequestParams(req)
  if (!parsed.ok) return parsed.response
  const params = parsed.params

  const grantType = params["grant_type"]
  if (grantType === "authorization_code") {
    const code = params["code"]
    const clientId = params["client_id"]
    const redirectUri = params["redirect_uri"]
    const verifier = params["code_verifier"]
    if (!code || !clientId || !redirectUri || !verifier) return badRequest("missing_params")

    const ac = store.getAuthCode(code, nowMs)
    if (!ac) return withJson({ error: "invalid_grant" }, { status: 400 })
    if (ac.usedAtMs != null) return withJson({ error: "invalid_grant" }, { status: 400 })
    if (ac.clientId !== clientId) return withJson({ error: "invalid_grant" }, { status: 400 })
    if (ac.redirectUri !== redirectUri) return withJson({ error: "invalid_grant" }, { status: 400 })

    const expected = ac.codeChallenge
    const computed = await sha256Base64Url(verifier)
    if (!constantTimeEq(expected, computed)) return withJson({ error: "invalid_grant" }, { status: 400 })

    const grant = store.getGrant(ac.grantId)
    if (!grant || grant.revokedAtMs != null) return withJson({ error: "invalid_grant" }, { status: 400 })

    store.markAuthCodeUsed(code, nowMs)

    const accessToken = `mcp_at_${base64Url(crypto.getRandomValues(new Uint8Array(32)))}`
    const accessHash = await sha256Hex(accessToken)
    store.createAccessToken({
      tokenHashHex: accessHash,
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + ACCESS_TOKEN_TTL_MS,
    })

    const wantsOffline = grant.scope.split(/\s+/).includes("offline_access")
    if (!wantsOffline) {
      return withJson(
        { access_token: accessToken, token_type: "bearer", expires_in: Math.floor(ACCESS_TOKEN_TTL_MS / 1000) },
        { headers: { "cache-control": "no-store" } },
      )
    }

    const refreshToken = `mcp_rt_${base64Url(crypto.getRandomValues(new Uint8Array(32)))}`
    const refreshHash = await sha256Hex(refreshToken)
    store.createRefreshToken({
      tokenHashHex: refreshHash,
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + REFRESH_TOKEN_TTL_MS,
    })

    return withJson(
      {
        access_token: accessToken,
        refresh_token: refreshToken,
        token_type: "bearer",
        expires_in: Math.floor(ACCESS_TOKEN_TTL_MS / 1000),
      },
      { headers: { "cache-control": "no-store" } },
    )
  }

  if (grantType === "refresh_token") {
    const refreshToken = params["refresh_token"]
    if (!refreshToken) return badRequest("missing_refresh_token")

    const hash = await sha256Hex(refreshToken)
    const existing = store.getRefreshToken(hash, nowMs)
    if (!existing) return withJson({ error: "invalid_grant" }, { status: 400 })

    const grant = store.getGrant(existing.grantId)
    if (!grant || grant.revokedAtMs != null) return withJson({ error: "invalid_grant" }, { status: 400 })

    const accessToken = `mcp_at_${base64Url(crypto.getRandomValues(new Uint8Array(32)))}`
    const accessHash = await sha256Hex(accessToken)
    store.createAccessToken({
      tokenHashHex: accessHash,
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + ACCESS_TOKEN_TTL_MS,
    })

    const newRefreshToken = `mcp_rt_${base64Url(crypto.getRandomValues(new Uint8Array(32)))}`
    const newRefreshHash = await sha256Hex(newRefreshToken)
    store.createRefreshToken({
      tokenHashHex: newRefreshHash,
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + REFRESH_TOKEN_TTL_MS,
    })
    store.revokeRefreshToken(hash, nowMs, newRefreshHash)

    return withJson(
      {
        access_token: accessToken,
        refresh_token: newRefreshToken,
        token_type: "bearer",
        expires_in: Math.floor(ACCESS_TOKEN_TTL_MS / 1000),
      },
      { headers: { "cache-control": "no-store" } },
    )
  }

  return badRequest("unsupported_grant_type")
}

async function handleRevoke(req: Request, store: Store): Promise<Response> {
  const parsed = await parseRequestParams(req)
  if (!parsed.ok) return parsed.response

  const token = parsed.params["token"]
  if (!token || !token.trim()) {
    return withJson({}, { headers: { "cache-control": "no-store" } })
  }

  const tokenHashHex = await sha256Hex(token)
  const grantId = store.findGrantIdByTokenHash(tokenHashHex)
  if (grantId) {
    const nowMs = Date.now()
    store.revokeGrant(grantId, nowMs)
    store.revokeRefreshTokensByGrant(grantId, nowMs)
  }

  return withJson({}, { headers: { "cache-control": "no-store" } })
}
