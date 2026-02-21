import { Elysia } from "elysia"
import { OauthModel } from "@in/server/db/models/oauth"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { oauthConfig } from "@in/server/modules/oauth/config"
import {
  MCP_SUPPORTED_SCOPES,
  base64UrlEncode,
  constantTimeEqual,
  createRandomToken,
  hasScope,
  isAllowedRedirectUri,
  normalizeEmail,
  normalizeRateLimitKeyPart,
  normalizeScopes,
  sha256Base64Url,
  sha256Hex,
} from "@inline-chat/oauth-core"
import {
  handler as sendEmailCodeHandler,
  Input as SendEmailCodeInput,
  Response as SendEmailCodeResponse,
} from "@in/server/methods/sendEmailCode"
import {
  handler as verifyEmailCodeHandler,
  Input as VerifyEmailCodeInput,
  Response as VerifyEmailCodeResponse,
} from "@in/server/methods/verifyEmailCode"
import { handler as getSpacesHandler } from "@in/server/methods/getSpaces"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { Value } from "@sinclair/typebox/value"
import { timingSafeEqual } from "node:crypto"

const config = oauthConfig()
const rateLimiter = new InMemoryRateLimiter()

const AUTH_REQUEST_COOKIE_PATH = "/oauth"

function authRequestCookieName(): string {
  return `${config.cookiePrefix}_ar`
}

function escapeHtml(input: string): string {
  return input.replace(/[&<>"']/g, (char) => {
    switch (char) {
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
      default:
        return char
    }
  })
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
    .card { max-width: 560px; border: 1px solid #e5e5e5; border-radius: 12px; padding: 20px; }
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

function json(status: number, body: unknown, headers?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      ...headers,
    },
  })
}

function html(status: number, body: string, headers?: HeadersInit): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      ...headers,
    },
  })
}

function parseCookie(req: Request, name: string): string | null {
  const header = req.headers.get("cookie")
  if (!header) return null

  for (const part of header.split(";")) {
    const idx = part.indexOf("=")
    if (idx < 0) continue
    const key = part.slice(0, idx).trim()
    if (key !== name) continue
    return part.slice(idx + 1).trim()
  }

  return null
}

function setCookieHeader(name: string, value: string, options?: { maxAgeSeconds?: number }): string {
  const secure = config.issuer.startsWith("https://")
  const maxAgePart = options?.maxAgeSeconds != null ? `; Max-Age=${options.maxAgeSeconds}` : ""
  return `${name}=${value}${maxAgePart}; Path=${AUTH_REQUEST_COOKIE_PATH}; HttpOnly; SameSite=Lax${secure ? "; Secure" : ""}`
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

function rateLimitedHtml(retryAfterSeconds: number, description: string): Response {
  return html(
    429,
    renderPage("Too many requests", `<div class=\"error\">${escapeHtml(description)}</div>`),
    { "retry-after": String(retryAfterSeconds) },
  )
}

function rateLimitedJson(retryAfterSeconds: number, description: string): Response {
  return json(429, { error: "rate_limited", error_description: description }, { "retry-after": String(retryAfterSeconds) })
}

function readParam(body: unknown, key: string): string {
  if (body instanceof FormData) {
    return String(body.get(key) ?? "")
  }

  if (body && typeof body === "object") {
    const value = (body as Record<string, unknown>)[key]
    if (Array.isArray(value)) {
      const first = value[0]
      return typeof first === "string" ? first : String(first ?? "")
    }
    return typeof value === "string" ? value : String(value ?? "")
  }

  return ""
}

function readAllParams(body: unknown, key: string): string[] {
  if (body instanceof FormData) {
    return body.getAll(key).map((value) => String(value))
  }

  if (body && typeof body === "object") {
    const value = (body as Record<string, unknown>)[key]
    if (Array.isArray(value)) {
      return value.map((item) => String(item))
    }
    if (value == null) return []
    return [String(value)]
  }

  return []
}

function parseRequestParams(body: unknown): Record<string, string> | null {
  if (!body || typeof body !== "object") {
    return {}
  }

  const params: Record<string, string> = {}
  for (const [key, value] of Object.entries(body as Record<string, unknown>)) {
    if (typeof value === "string") {
      params[key] = value
      continue
    }
    if (Array.isArray(value) && value.length > 0) {
      params[key] = String(value[0])
    }
  }
  return params
}

function verifyInternalSecret(req: Request): boolean {
  if (!config.internalSharedSecret) {
    return false
  }

  const provided = req.headers.get("x-inline-mcp-secret") ?? ""
  const expectedBytes = Buffer.from(config.internalSharedSecret)
  const providedBytes = Buffer.from(provided)
  if (expectedBytes.length !== providedBytes.length) {
    return false
  }

  return timingSafeEqual(expectedBytes, providedBytes)
}

async function getAuthRequestFromCookie(req: Request): Promise<Awaited<ReturnType<typeof OauthModel.getAuthRequest>>> {
  const id = parseCookie(req, authRequestCookieName())
  if (!id) return null
  return await OauthModel.getAuthRequest(id, Date.now())
}

async function getSpacesForToken(token: string): Promise<Array<{ id: number; name: string }>> {
  const { userId, sessionId } = await getUserIdFromToken(token)
  const spaces = await getSpacesHandler(undefined as never, {
    currentUserId: userId,
    currentSessionId: sessionId,
    ip: undefined,
  })

  return spaces.spaces.map((space) => ({ id: space.id, name: space.name }))
}

async function handleRegister(req: Request, body: unknown): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(req)
  rateLimiter.cleanup(nowMs)

  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:register:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.register,
  })
  if (!endpointRate.allowed) {
    return rateLimitedJson(endpointRate.retryAfterSeconds, "Too many client registration requests.")
  }

  if (!body || typeof body !== "object") {
    return json(400, { error: "invalid_json" })
  }

  const redirectUrisRaw = (body as Record<string, unknown>)["redirect_uris"]
  if (!Array.isArray(redirectUrisRaw) || redirectUrisRaw.length === 0) {
    return json(400, { error: "missing_redirect_uris" })
  }

  if (!redirectUrisRaw.every((value) => typeof value === "string")) {
    return json(400, { error: "invalid_redirect_uris" })
  }

  const redirectUris = redirectUrisRaw.map((uri) => uri.trim())
  if (redirectUris.some((uri) => !uri || !isAllowedRedirectUri(uri))) {
    return json(400, { error: "invalid_redirect_uri" })
  }

  const clientNameRaw = (body as Record<string, unknown>)["client_name"]
  const clientName = typeof clientNameRaw === "string" && clientNameRaw.trim().length > 0 ? clientNameRaw.trim() : null

  const clientId = crypto.randomUUID()
  const client = await OauthModel.createClient({
    clientId,
    redirectUris,
    clientName,
    nowMs,
  })

  return json(
    201,
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
      "cache-control": "no-store",
    },
  )
}

async function handleAuthorizeGet(url: URL): Promise<Response> {
  const responseType = url.searchParams.get("response_type")
  const clientId = url.searchParams.get("client_id")
  const redirectUri = url.searchParams.get("redirect_uri")
  const state = url.searchParams.get("state")
  const scopeRaw = url.searchParams.get("scope") ?? ""
  const codeChallenge = url.searchParams.get("code_challenge")
  const codeChallengeMethod = url.searchParams.get("code_challenge_method") ?? "S256"

  if (responseType !== "code") return json(400, { error: "invalid_response_type" })
  if (!clientId || !redirectUri || !state || !codeChallenge) return json(400, { error: "missing_params" })
  if (codeChallengeMethod !== "S256") return json(400, { error: "invalid_code_challenge_method" })

  const client = await OauthModel.getClient(clientId)
  if (!client) return json(400, { error: "invalid_client" })
  if (!client.redirectUris.includes(redirectUri)) return json(400, { error: "invalid_redirect_uri" })

  const nowMs = Date.now()
  const authRequestId = crypto.randomUUID()
  const csrfToken = base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)))
  const deviceId = crypto.randomUUID()

  await OauthModel.createAuthRequest({
    id: authRequestId,
    clientId,
    redirectUri,
    state,
    scope: normalizeScopes(scopeRaw),
    codeChallenge,
    csrfToken,
    deviceId,
    nowMs,
    expiresAtMs: nowMs + config.authRequestTtlMs,
  })

  const cookie = setCookieHeader(authRequestCookieName(), authRequestId)

  return html(
    200,
    renderPage(
      "Sign in to Inline",
      `
<form method="post" action="/oauth/authorize/send-email-code">
  <input type="hidden" name="csrf" value="${escapeHtml(csrfToken)}" />
  <label>Email</label>
  <input name="email" type="email" autocomplete="email" required />
  <button type="submit">Send code</button>
  <div class="muted">You will receive a 6-digit code.</div>
</form>`,
    ),
    {
      "set-cookie": cookie,
      "cache-control": "no-store",
    },
  )
}

async function handleAuthorizeSendEmailCode(req: Request, body: unknown): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(req)
  rateLimiter.cleanup(nowMs)

  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:send-email-code:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.sendEmailCode,
  })

  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many email-code requests. Try again shortly.")
  }

  const authRequest = await getAuthRequestFromCookie(req)
  if (!authRequest) {
    return html(400, renderPage("Error", `<div class=\"error\">Session expired. Please try again.</div>`))
  }

  const csrf = readParam(body, "csrf")
  const email = normalizeEmail(readParam(body, "email"))

  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class=\"error\">Invalid CSRF token.</div>`))
  }

  if (!email || !email.includes("@")) {
    return html(400, renderPage("Error", `<div class=\"error\">Invalid email.</div>`))
  }

  const emailHash = await sha256Hex(email)
  const perEmail = rateLimiter.consume({
    key: `oauth:abuse:send-email:email:${emailHash}`,
    nowMs,
    rule: config.emailAbuseRateLimits.sendPerEmail,
  })
  if (!perEmail.allowed) {
    return rateLimitedHtml(perEmail.retryAfterSeconds, "Too many attempts for this email. Try again later.")
  }

  const perContext = rateLimiter.consume({
    key: `oauth:abuse:send-email:context:${emailHash}:${normalizeRateLimitKeyPart(authRequest.clientId)}:${normalizeRateLimitKeyPart(authRequest.deviceId)}:${clientIp}`,
    nowMs,
    rule: config.emailAbuseRateLimits.sendPerContext,
  })
  if (!perContext.allowed) {
    return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context. Try again later.")
  }

  let sendResult: unknown
  try {
    const input = Value.Decode(SendEmailCodeInput, { email })
    sendResult = await sendEmailCodeHandler(input, { ip: clientIp })
    if (!Value.Check(SendEmailCodeResponse, sendResult)) {
      throw new Error("invalid sendEmailCode response")
    }
  } catch {
    return html(502, renderPage("Error", `<div class=\"error\">Failed to send code.</div>`))
  }

  const challengeToken = typeof (sendResult as Record<string, unknown>)["challengeToken"] === "string"
    ? String((sendResult as Record<string, unknown>)["challengeToken"])
    : ""

  if (!challengeToken) {
    return html(500, renderPage("Error", `<div class=\"error\">Login challenge unavailable.</div>`))
  }

  await OauthModel.setAuthRequestEmail(authRequest.id, email, challengeToken)

  return html(
    200,
    renderPage(
      "Enter code",
      `
<form method="post" action="/oauth/authorize/verify-email-code">
  <input type="hidden" name="csrf" value="${escapeHtml(authRequest.csrfToken)}" />
  <label>Code</label>
  <input name="code" inputmode="numeric" autocomplete="one-time-code" required />
  <button type="submit">Verify</button>
  <div class="muted">Sent to <code>${escapeHtml(email)}</code>.</div>
</form>`,
    ),
    { "cache-control": "no-store" },
  )
}

async function handleAuthorizeVerifyEmailCode(req: Request, body: unknown): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(req)
  rateLimiter.cleanup(nowMs)

  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:verify-email-code:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.verifyEmailCode,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many verification attempts. Try again shortly.")
  }

  const authRequest = await getAuthRequestFromCookie(req)
  if (!authRequest) {
    return html(400, renderPage("Error", `<div class=\"error\">Session expired. Please try again.</div>`))
  }

  if (!authRequest.email || !authRequest.challengeToken) {
    return html(400, renderPage("Error", `<div class=\"error\">Missing email challenge. Start over.</div>`))
  }

  const csrf = readParam(body, "csrf")
  const code = readParam(body, "code").trim()

  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class=\"error\">Invalid CSRF token.</div>`))
  }

  if (!code || code.length < 6) {
    return html(400, renderPage("Error", `<div class=\"error\">Invalid code.</div>`))
  }

  const normalizedEmail = normalizeEmail(authRequest.email)
  const emailHash = await sha256Hex(normalizedEmail)

  const perEmail = rateLimiter.consume({
    key: `oauth:abuse:verify-email:email:${emailHash}`,
    nowMs,
    rule: config.emailAbuseRateLimits.verifyPerEmail,
  })
  if (!perEmail.allowed) {
    return rateLimitedHtml(perEmail.retryAfterSeconds, "Too many verification attempts for this email. Try again later.")
  }

  const perContext = rateLimiter.consume({
    key: `oauth:abuse:verify-email:context:${emailHash}:${normalizeRateLimitKeyPart(authRequest.clientId)}:${normalizeRateLimitKeyPart(authRequest.deviceId)}:${clientIp}`,
    nowMs,
    rule: config.emailAbuseRateLimits.verifyPerContext,
  })
  if (!perContext.allowed) {
    return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context. Try again later.")
  }

  let verifyResult: unknown
  try {
    const input = Value.Decode(VerifyEmailCodeInput, {
      email: normalizedEmail,
      code,
      challengeToken: authRequest.challengeToken,
      deviceId: authRequest.deviceId,
      clientType: "web",
      deviceName: "ChatGPT MCP",
    })
    verifyResult = await verifyEmailCodeHandler(input, { ip: clientIp })
    if (!Value.Check(VerifyEmailCodeResponse, verifyResult)) {
      throw new Error("invalid verifyEmailCode response")
    }
  } catch {
    return html(401, renderPage("Error", `<div class=\"error\">Code verification failed.</div>`))
  }

  const token = String((verifyResult as Record<string, unknown>)["token"] ?? "")
  const userId = Number((verifyResult as Record<string, unknown>)["userId"] ?? 0)

  if (!token || !Number.isInteger(userId) || userId <= 0) {
    return html(500, renderPage("Error", `<div class=\"error\">Invalid login session.</div>`))
  }

  let encryptedToken: Buffer
  try {
    encryptedToken = Encryption2.encrypt(Buffer.from(token, "utf8"))
  } catch {
    return html(500, renderPage("Error", `<div class=\"error\">Server misconfigured.</div>`))
  }

  await OauthModel.setAuthRequestInlineSession({
    id: authRequest.id,
    inlineUserId: userId,
    inlineTokenEncrypted: encryptedToken,
  })

  let spaces: Array<{ id: number; name: string }> = []
  try {
    spaces = await getSpacesForToken(token)
  } catch {
    return html(502, renderPage("Error", `<div class=\"error\">Failed to load spaces.</div>`))
  }

  const spacesList = spaces
    .map((space) => {
      return `<label><input type=\"checkbox\" name=\"space_id\" value=\"${String(space.id)}\" checked /> ${escapeHtml(space.name)}</label>`
    })
    .join("")

  return html(
    200,
    renderPage(
      "Choose access",
      `
<form method="post" action="/oauth/authorize/consent">
  <input type="hidden" name="csrf" value="${escapeHtml(authRequest.csrfToken)}" />
  <div class="muted">Requested scopes: <code>${escapeHtml(authRequest.scope)}</code></div>
  <div class="spaces">
    ${spacesList}
    <label><input type="checkbox" name="allow_dms" value="1" checked /> DMs</label>
    <label><input type="checkbox" name="allow_home_threads" value="1" checked /> Home threads (threads shared with you)</label>
  </div>
  <button type="submit">Allow</button>
</form>`,
    ),
    { "cache-control": "no-store" },
  )
}

async function handleAuthorizeConsent(req: Request, body: unknown): Promise<Response> {
  const authRequest = await getAuthRequestFromCookie(req)
  if (!authRequest) {
    return html(400, renderPage("Error", `<div class=\"error\">Session expired. Please try again.</div>`))
  }

  if (!authRequest.inlineTokenEncrypted || !authRequest.inlineUserId) {
    return html(400, renderPage("Error", `<div class=\"error\">Not signed in.</div>`))
  }

  const csrf = readParam(body, "csrf")
  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class=\"error\">Invalid CSRF token.</div>`))
  }

  const selectedSpaceIds = readAllParams(body, "space_id")
  const allowDms = readParam(body, "allow_dms") === "1"
  const allowHomeThreads = readParam(body, "allow_home_threads") === "1"

  if (selectedSpaceIds.length === 0 && !allowDms && !allowHomeThreads) {
    return html(400, renderPage("Error", `<div class=\"error\">Select at least one space, DMs, or home threads.</div>`))
  }

  let token: string
  try {
    token = Encryption2.decryptToString(authRequest.inlineTokenEncrypted)
  } catch {
    return html(400, renderPage("Error", `<div class=\"error\">Invalid session.</div>`))
  }

  let availableSpaces: Array<{ id: number; name: string }> = []
  try {
    availableSpaces = await getSpacesForToken(token)
  } catch {
    return html(502, renderPage("Error", `<div class=\"error\">Failed to load spaces.</div>`))
  }

  const availableSpaceIdSet = new Set(availableSpaces.map((space) => String(space.id)))
  const chosenSpaceIds = selectedSpaceIds.filter((id) => availableSpaceIdSet.has(id)).map((id) => BigInt(id))

  if (chosenSpaceIds.length === 0 && !allowDms && !allowHomeThreads) {
    return html(400, renderPage("Error", `<div class=\"error\">Invalid space selection.</div>`))
  }

  const nowMs = Date.now()
  const grantId = crypto.randomUUID()
  const grant = await OauthModel.createGrant({
    id: grantId,
    clientId: authRequest.clientId,
    inlineUserId: authRequest.inlineUserId,
    scope: authRequest.scope,
    spaceIds: chosenSpaceIds,
    allowDms,
    allowHomeThreads,
    inlineTokenEncrypted: authRequest.inlineTokenEncrypted,
    nowMs,
  })

  const authCode = createRandomToken("mcp_ac")
  await OauthModel.createAuthCode({
    code: authCode,
    grantId: grant.id,
    clientId: grant.clientId,
    redirectUri: authRequest.redirectUri,
    codeChallenge: authRequest.codeChallenge,
    nowMs,
    expiresAtMs: nowMs + config.authCodeTtlMs,
  })

  await OauthModel.deleteAuthRequest(authRequest.id)

  const redirect = new URL(authRequest.redirectUri)
  redirect.searchParams.set("code", authCode)
  redirect.searchParams.set("state", authRequest.state)

  return new Response(null, {
    status: 302,
    headers: {
      location: redirect.toString(),
      "set-cookie": setCookieHeader(authRequestCookieName(), "", { maxAgeSeconds: 0 }),
    },
  })
}

async function handleToken(req: Request, body: unknown): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(req)
  rateLimiter.cleanup(nowMs)

  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:token:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.token,
  })
  if (!endpointRate.allowed) {
    return rateLimitedJson(endpointRate.retryAfterSeconds, "Too many token requests.")
  }

  const params = parseRequestParams(body)
  if (!params) return json(400, { error: "invalid_json" })

  const grantType = params["grant_type"]
  if (grantType === "authorization_code") {
    const code = params["code"]
    const clientId = params["client_id"]
    const redirectUri = params["redirect_uri"]
    const verifier = params["code_verifier"]

    if (!code || !clientId || !redirectUri || !verifier) {
      return json(400, { error: "missing_params" })
    }

    const authCode = await OauthModel.getAuthCode(code, nowMs)
    if (!authCode || authCode.usedAtMs != null) return json(400, { error: "invalid_grant" })
    if (authCode.clientId !== clientId) return json(400, { error: "invalid_grant" })
    if (authCode.redirectUri !== redirectUri) return json(400, { error: "invalid_grant" })

    const computedChallenge = await sha256Base64Url(verifier)
    if (!constantTimeEqual(authCode.codeChallenge, computedChallenge)) {
      return json(400, { error: "invalid_grant" })
    }

    const grant = await OauthModel.getGrant(authCode.grantId)
    if (!grant || grant.revokedAtMs != null) {
      return json(400, { error: "invalid_grant" })
    }

    await OauthModel.markAuthCodeUsed(code, nowMs)

    const accessToken = createRandomToken("mcp_at")
    const accessHash = await sha256Hex(accessToken)
    await OauthModel.createAccessToken({
      tokenHash: accessHash,
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + config.accessTokenTtlMs,
    })

    const baseResponse = {
      access_token: accessToken,
      token_type: "bearer",
      expires_in: Math.floor(config.accessTokenTtlMs / 1000),
      scope: grant.scope,
    }

    if (!hasScope(grant.scope, "offline_access")) {
      return json(200, baseResponse, { "cache-control": "no-store" })
    }

    const refreshToken = createRandomToken("mcp_rt")
    const refreshHash = await sha256Hex(refreshToken)
    await OauthModel.createRefreshToken({
      tokenHash: refreshHash,
      grantId: grant.id,
      nowMs,
      expiresAtMs: nowMs + config.refreshTokenTtlMs,
    })

    return json(
      200,
      {
        ...baseResponse,
        refresh_token: refreshToken,
      },
      { "cache-control": "no-store" },
    )
  }

  if (grantType === "refresh_token") {
    const refreshToken = params["refresh_token"]
    const clientId = params["client_id"]
    if (!refreshToken) {
      return json(400, { error: "missing_refresh_token" })
    }
    if (!clientId) {
      return json(400, { error: "missing_client_id" })
    }

    const refreshHash = await sha256Hex(refreshToken)
    const result = await OauthModel.getGrantForRefreshTokenHash(refreshHash, nowMs)
    if (!result) {
      return json(400, { error: "invalid_grant" })
    }
    if (result.grant.clientId !== clientId) {
      return json(400, { error: "invalid_grant" })
    }

    const accessToken = createRandomToken("mcp_at")
    const accessHash = await sha256Hex(accessToken)

    const newRefreshToken = createRandomToken("mcp_rt")
    const newRefreshHash = await sha256Hex(newRefreshToken)

    await Promise.all([
      OauthModel.createAccessToken({
        tokenHash: accessHash,
        grantId: result.grant.id,
        nowMs,
        expiresAtMs: nowMs + config.accessTokenTtlMs,
      }),
      OauthModel.createRefreshToken({
        tokenHash: newRefreshHash,
        grantId: result.grant.id,
        nowMs,
        expiresAtMs: nowMs + config.refreshTokenTtlMs,
      }),
      OauthModel.revokeRefreshToken(refreshHash, nowMs, newRefreshHash),
    ])

    return json(
      200,
      {
        access_token: accessToken,
        refresh_token: newRefreshToken,
        token_type: "bearer",
        expires_in: Math.floor(config.accessTokenTtlMs / 1000),
        scope: result.grant.scope,
      },
      { "cache-control": "no-store" },
    )
  }

  return json(400, { error: "unsupported_grant_type" })
}

async function handleRevoke(body: unknown): Promise<Response> {
  const params = parseRequestParams(body)
  if (!params) return json(400, { error: "invalid_json" })

  const token = params["token"]
  if (!token || !token.trim()) {
    return json(200, {}, { "cache-control": "no-store" })
  }

  const tokenHash = await sha256Hex(token)
  await OauthModel.revokeGrantByAnyTokenHash(tokenHash, Date.now())

  return json(200, {}, { "cache-control": "no-store" })
}

async function handleIntrospect(req: Request, body: unknown): Promise<Response> {
  if (!verifyInternalSecret(req)) {
    return json(401, { error: "unauthorized" })
  }

  const params = parseRequestParams(body)
  if (!params) return json(400, { error: "invalid_json" })

  const token = params["token"]
  if (!token) {
    return json(400, { error: "missing_token" })
  }

  const tokenHash = await sha256Hex(token)
  const nowMs = Date.now()
  const result = await OauthModel.getGrantByActiveAccessTokenHash(tokenHash, nowMs)
  if (!result) {
    return json(401, { active: false })
  }

  let inlineToken: string
  try {
    inlineToken = Encryption2.decryptToString(result.grant.inlineTokenEncrypted)
  } catch {
    return json(500, { error: "invalid_grant_session" })
  }

  return json(200, {
    active: true,
    grant_id: result.grant.id,
    client_id: result.grant.clientId,
    scope: result.grant.scope,
    exp: Math.floor(result.accessToken.expiresAtMs / 1000),
    inline_user_id: String(result.grant.inlineUserId),
    space_ids: result.grant.spaceIds.map((spaceId) => spaceId.toString()),
    allow_dms: result.grant.allowDms,
    allow_home_threads: result.grant.allowHomeThreads,
    inline_token: inlineToken,
  })
}

export const oauth = new Elysia({ name: "oauth" })
  .get("/.well-known/oauth-authorization-server", async () => {
    void OauthModel.cleanupExpired(Date.now()).catch(() => undefined)

    return json(200, {
      issuer: config.issuer,
      authorization_endpoint: `${config.issuer}/oauth/authorize`,
      token_endpoint: `${config.issuer}/oauth/token`,
      registration_endpoint: `${config.issuer}/oauth/register`,
      revocation_endpoint: `${config.issuer}/oauth/revoke`,
      scopes_supported: [...MCP_SUPPORTED_SCOPES],
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none"],
      code_challenge_methods_supported: ["S256"],
    })
  })
  .post("/oauth/register", async ({ request, body }) => {
    return await handleRegister(request, body)
  })
  .post("/register", async ({ request, body }) => {
    return await handleRegister(request, body)
  })
  .get("/oauth/authorize", async ({ request }) => {
    void OauthModel.cleanupExpired(Date.now()).catch(() => undefined)
    return await handleAuthorizeGet(new URL(request.url))
  })
  .get("/authorize", async ({ request }) => {
    void OauthModel.cleanupExpired(Date.now()).catch(() => undefined)
    return await handleAuthorizeGet(new URL(request.url))
  })
  .post("/oauth/authorize/send-email-code", async ({ request, body }) => {
    return await handleAuthorizeSendEmailCode(request, body)
  })
  .post("/oauth/authorize/verify-email-code", async ({ request, body }) => {
    return await handleAuthorizeVerifyEmailCode(request, body)
  })
  .post("/oauth/authorize/consent", async ({ request, body }) => {
    return await handleAuthorizeConsent(request, body)
  })
  .post("/oauth/token", async ({ request, body }) => {
    return await handleToken(request, body)
  })
  .post("/token", async ({ request, body }) => {
    return await handleToken(request, body)
  })
  .post("/oauth/revoke", async ({ body }) => {
    return await handleRevoke(body)
  })
  .post("/revoke", async ({ body }) => {
    return await handleRevoke(body)
  })
  .post("/oauth/introspect", async ({ request, body }) => {
    return await handleIntrospect(request, body)
  })
