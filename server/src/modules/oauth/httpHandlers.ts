import { OauthModel, type OauthAuthRequest } from "@in/server/db/models/oauth"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { oauthConfig } from "@in/server/modules/oauth/config"
import {
  MCP_SUPPORTED_SCOPES,
  base64UrlEncode,
  constantTimeEqual,
  createRandomToken,
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
import {
  handler as sendSmsCodeHandler,
  Input as SendSmsCodeInput,
  Response as SendSmsCodeResponse,
} from "@in/server/methods/sendSmsCode"
import {
  handler as verifySmsCodeHandler,
  Input as VerifySmsCodeInput,
  Response as VerifySmsCodeResponse,
} from "@in/server/methods/verifySmsCode"
import { handler as getSpacesHandler } from "@in/server/methods/getSpaces"
import {
  getUserIdFromToken,
} from "@in/server/modules/auth/sessionAuthentication"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { Value } from "@sinclair/typebox/value"
import { timingSafeEqual } from "node:crypto"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { OAuthHandlerFailure } from "./httpHandlerFailure"
import parsePhoneNumber from "libphonenumber-js"

const config = oauthConfig()
// TODO(effect-cutover): remove this oracle-only limiter with legacyServer.ts
// after the post-cutover differential window. Production injects a separately
// scoped limiter through its Effect Layer.
const legacyRateLimiter = new InMemoryRateLimiter()

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
    :root { color-scheme: light dark; font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 28px 20px; color: #171717; background: #f7f7f5; }
    .shell { width: 100%; max-width: 440px; }
    .brand { display: flex; align-items: center; justify-content: center; gap: 9px; margin-bottom: 22px; font-size: 17px; font-weight: 700; letter-spacing: -0.02em; }
    .brand svg { width: 27px; height: 27px; }
    .card { border: 1px solid #dededb; border-radius: 18px; padding: 30px; background: #fff; box-shadow: 0 12px 40px rgba(21, 21, 19, 0.06); }
    h1 { margin: 0; font-size: 25px; line-height: 1.2; letter-spacing: -0.035em; }
    .intro { margin: 9px 0 24px; color: #666661; font-size: 14px; line-height: 1.5; }
    label { display: block; margin-top: 16px; font-size: 13px; font-weight: 650; }
    input[type="email"], input[type="tel"], input[name="code"] { width: 100%; min-height: 46px; padding: 11px 13px; margin-top: 7px; border-radius: 10px; border: 1px solid #cececa; background: #fff; color: #171717; font: inherit; font-size: 15px; outline: none; transition: border-color 120ms ease, box-shadow 120ms ease; }
    input[type="email"]:focus, input[type="tel"]:focus, input[name="code"]:focus { border-color: #343431; box-shadow: 0 0 0 3px rgba(30, 30, 28, 0.1); }
    input[name="code"] { letter-spacing: 0.16em; font-variant-numeric: tabular-nums; }
    button { width: 100%; min-height: 46px; margin-top: 20px; padding: 11px 16px; border-radius: 11px; border: 1px solid #171717; background: #171717; color: #fff; font: inherit; font-size: 14px; font-weight: 650; cursor: pointer; transition: background 120ms ease, transform 120ms ease; }
    button:hover { background: #30302d; }
    button:active { transform: translateY(1px); }
    .muted { color: #777771; font-size: 12px; line-height: 1.45; margin-top: 11px; }
    .error { padding: 12px 14px; border: 1px solid #edc9c5; border-radius: 10px; background: #fff6f5; color: #9d2d23; font-size: 14px; line-height: 1.45; }
    .method-tabs { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; padding: 4px; margin-bottom: 20px; border-radius: 11px; background: #f0f0ed; }
    .method-tabs label { margin: 0; padding: 8px 10px; border-radius: 8px; color: #6b6b66; text-align: center; cursor: pointer; }
    .method-tabs input { position: absolute; width: 1px; height: 1px; opacity: 0; pointer-events: none; }
    .method-tabs label:has(input:checked) { background: #fff; color: #171717; box-shadow: 0 1px 3px rgba(20, 20, 18, 0.1); }
    .method-tabs label:has(input:focus-visible) { outline: 2px solid currentColor; outline-offset: 2px; }
    .sign-in-method { display: none; }
    .card:has(#method-email:checked) .email-method, .card:has(#method-phone:checked) .phone-method { display: block; }
    .scope { padding: 12px 14px; margin: 18px 0; border: 1px solid #e4e4e0; border-radius: 10px; background: #fafaf8; }
    .scope .muted { margin: 0 0 5px; }
    .spaces { max-height: 290px; overflow-y: auto; margin: 0 -6px; padding: 0 6px; }
    .spaces label { display: flex; align-items: center; gap: 11px; min-height: 39px; margin: 0; border-bottom: 1px solid #eeeeeb; font-size: 14px; font-weight: 500; }
    .spaces label:last-child { border-bottom: 0; }
    .spaces input { width: 17px; height: 17px; margin: 0; accent-color: #171717; }
    code { padding: 2px 5px; border-radius: 5px; background: #efefec; font-size: 11px; overflow-wrap: anywhere; }
    .trust { margin: 18px 4px 0; color: #85857f; font-size: 11px; line-height: 1.5; text-align: center; }
    @media (max-width: 520px) { body { align-items: start; padding: 22px 14px; } .brand { margin-bottom: 18px; } .card { padding: 24px 20px; border-radius: 16px; } }
    @media (prefers-color-scheme: dark) {
      body { color: #f3f3f0; background: #111210; }
      .card { border-color: #343532; background: #1b1c19; box-shadow: none; }
      .intro, .muted { color: #a7a8a1; }
      input[type="email"], input[type="tel"], input[name="code"] { border-color: #464742; background: #22231f; color: #f3f3f0; }
      input[type="email"]:focus, input[type="tel"]:focus, input[name="code"]:focus { border-color: #d0d0ca; box-shadow: 0 0 0 3px rgba(240, 240, 235, 0.1); }
      button { border-color: #f1f1ed; background: #f1f1ed; color: #181916; }
      button:hover { background: #dcdcd7; }
      .method-tabs { background: #252622; }
      .method-tabs label { color: #a1a29b; }
      .method-tabs label:has(input:checked) { background: #3a3b36; color: #f3f3f0; box-shadow: none; }
      .scope { border-color: #363732; background: #21221f; }
      .spaces label { border-color: #30312d; }
      .spaces input { accent-color: #f1f1ed; }
      code { background: #30312d; }
      .error { border-color: #663e39; background: #2d1d1b; color: #f1aaa2; }
      .trust { color: #878881; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <div class="brand">
      <svg viewBox="0 0 54 54" fill="none" aria-hidden="true"><rect x="5" y="5" width="44" height="44" rx="16" stroke="currentColor" stroke-width="10"/><rect x="17" y="17" width="10" height="20" rx="4" fill="currentColor"/></svg>
      <span>Inline</span>
    </div>
    <div class="card">
      <h1>${escapeHtml(title)}</h1>
      ${body}
    </div>
    <div class="trust">Secure sign-in · Verification codes stay between you and Inline.</div>
  </main>
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

function resolveClientIp(clientIp: string | undefined): string {
  return clientIp?.trim()
    ? normalizeRateLimitKeyPart(clientIp)
    : "unknown"
}

const privateCause = (cause: unknown): unknown =>
  cause instanceof InlineError
    ? cause.cause ?? cause
    : cause

function rateLimitedHtml(retryAfterSeconds: number, description: string): Response {
  return html(
    429,
    renderPage("Too many requests", `<div class="error">${escapeHtml(description)}</div>`),
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

async function completeAuthorizeSignIn(
  authRequest: OauthAuthRequest,
  verifyResult: unknown,
  method: "email" | "phone",
): Promise<Response> {
  const token = String((verifyResult as Record<string, unknown>)["token"] ?? "")
  const userId = Number((verifyResult as Record<string, unknown>)["userId"] ?? 0)

  if (!token || !Number.isInteger(userId) || userId <= 0) {
    const response = html(500, renderPage("Error", `<div class="error">Invalid login session.</div>`))
    throw new OAuthHandlerFailure(
      `OAuth ${method} verification returned an invalid login session.`,
      {
        cause: new Error(`${method} verification returned an invalid login session`),
        response,
      },
    )
  }

  let encryptedToken: Buffer
  try {
    encryptedToken = Encryption2.encrypt(Buffer.from(token, "utf8"))
  } catch (cause) {
    const response = html(500, renderPage("Error", `<div class="error">Server misconfigured.</div>`))
    throw new OAuthHandlerFailure(
      "OAuth session token encryption failed.",
      { cause, response },
    )
  }

  await OauthModel.setAuthRequestInlineSession({
    id: authRequest.id,
    inlineUserId: userId,
    inlineTokenEncrypted: encryptedToken,
  })

  let spaces: Array<{ id: number; name: string }> = []
  try {
    spaces = await getSpacesForToken(token)
  } catch (cause) {
    const response = html(502, renderPage("Error", `<div class="error">Failed to load spaces.</div>`))
    throw new OAuthHandlerFailure(
      "OAuth space loading failed.",
      {
        cause: privateCause(cause),
        response,
      },
    )
  }

  const spacesList = spaces
    .map((space) => {
      return `<label><input type="checkbox" name="space_id" value="${String(space.id)}" checked /> <span>${escapeHtml(space.name)}</span></label>`
    })
    .join("")
  const client = await OauthModel.getClient(authRequest.clientId)
  const clientName = client?.clientName?.trim() || "the connected app"

  return html(
    200,
    renderPage(
      "Choose what to share",
      `
<p class="intro">Select where ${escapeHtml(clientName)} can act on your behalf. You can revoke access later.</p>
<form method="post" action="/oauth/authorize/consent">
  <input type="hidden" name="csrf" value="${escapeHtml(authRequest.csrfToken)}" />
  <div class="scope">
    <div class="muted">Requested permissions</div>
    <code>${escapeHtml(authRequest.scope)}</code>
  </div>
  <div class="spaces">
    ${spacesList}
    <label><input type="checkbox" name="allow_dms" value="1" checked /> <span>Direct messages</span></label>
    <label><input type="checkbox" name="allow_home_threads" value="1" checked /> <span>Home threads shared with you</span></label>
  </div>
  <button type="submit">Allow access</button>
</form>`,
    ),
    { "cache-control": "no-store" },
  )
}

export async function handleRegister(
  req: Request,
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)

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

export async function handleAuthorizeGet(url: URL): Promise<Response> {
  const responseType = url.searchParams.get("response_type")
  const clientId = url.searchParams.get("client_id")
  const redirectUri = url.searchParams.get("redirect_uri")
  const state = url.searchParams.get("state")
  const scopeRaw = url.searchParams.get("scope") ?? ""
  const requestedResource = url.searchParams.get("resource")
  const codeChallenge = url.searchParams.get("code_challenge")
  const codeChallengeMethod = url.searchParams.get("code_challenge_method") ?? "S256"

  if (responseType !== "code") return json(400, { error: "invalid_response_type" })
  if (!clientId || !redirectUri || !state || !codeChallenge) return json(400, { error: "missing_params" })
  if (codeChallengeMethod !== "S256") return json(400, { error: "invalid_code_challenge_method" })
  if (requestedResource != null && requestedResource !== config.resource) {
    return json(400, { error: "invalid_target" })
  }

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
    resource: requestedResource ?? config.resource,
    codeChallenge,
    csrfToken,
    deviceId,
    nowMs,
    expiresAtMs: nowMs + config.authRequestTtlMs,
  })

  const cookie = setCookieHeader(authRequestCookieName(), authRequestId)
  const signInDescription = client.clientName?.trim()
    ? `Continue to <strong>${escapeHtml(client.clientName.trim())}</strong> using the email address or phone number linked to your Inline account.`
    : "Use the email address or phone number linked to your Inline account."

  return html(
    200,
    renderPage(
      "Sign in to Inline",
      `
<p class="intro">${signInDescription}</p>
<div class="method-tabs" role="radiogroup" aria-label="Sign-in method">
  <label><input id="method-email" type="radio" name="sign-in-method" checked />Email</label>
  <label><input id="method-phone" type="radio" name="sign-in-method" />Phone</label>
</div>
<form class="sign-in-method email-method" method="post" action="/oauth/authorize/send-email-code">
  <input type="hidden" name="csrf" value="${escapeHtml(csrfToken)}" />
  <label>Email address
    <input name="email" type="email" autocomplete="email" placeholder="you@example.com" required autofocus />
  </label>
  <button type="submit">Continue with email</button>
</form>
<form class="sign-in-method phone-method" method="post" action="/oauth/authorize/send-sms-code">
  <input type="hidden" name="csrf" value="${escapeHtml(csrfToken)}" />
  <label>Phone number
    <input name="phone_number" type="tel" inputmode="tel" autocomplete="tel" placeholder="+1 202 555 0123" required />
  </label>
  <button type="submit">Continue with phone</button>
</form>
<div class="muted">We’ll send you a 6-digit verification code.</div>`,
    ),
    {
      "set-cookie": cookie,
      "cache-control": "no-store",
    },
  )
}

export async function handleAuthorizeSendEmailCode(
  req: Request,
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)

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
    return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  }

  const csrf = readParam(body, "csrf")
  const email = normalizeEmail(readParam(body, "email"))

  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }

  if (!email || !email.includes("@")) {
    return html(400, renderPage("Error", `<div class="error">Invalid email.</div>`))
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
    const input = Value.Decode(SendEmailCodeInput, {
      email,
      deviceId: authRequest.deviceId,
      clientType: "web",
      deviceName: "OAuth",
    })
    sendResult = await sendEmailCodeHandler(input, { ip: clientIp, source: "/oauth/authorize/send-email-code" })
    if (!Value.Check(SendEmailCodeResponse, sendResult)) {
      throw new Error("invalid sendEmailCode response")
    }
  } catch (cause) {
    const response = html(502, renderPage("Error", `<div class="error">Failed to send code.</div>`))
    if (cause instanceof InlineError && cause.code < 500) {
      return response
    }
    throw new OAuthHandlerFailure(
      "OAuth email-code delivery failed.",
      {
        cause: privateCause(cause),
        response,
      },
    )
  }

  const challengeToken = typeof (sendResult as Record<string, unknown>)["challengeToken"] === "string"
    ? String((sendResult as Record<string, unknown>)["challengeToken"])
    : ""

  if (!challengeToken) {
    const response = html(500, renderPage("Error", `<div class="error">Login challenge unavailable.</div>`))
    throw new OAuthHandlerFailure(
      "OAuth email-code delivery returned no challenge token.",
      {
        cause: new Error(
          "sendEmailCode returned no challenge token",
        ),
        response,
      },
    )
  }

  await OauthModel.setAuthRequestEmail(authRequest.id, email, challengeToken)

  return html(
    200,
    renderPage(
      "Check your email",
      `
<p class="intro">Enter the verification code sent to <strong>${escapeHtml(email)}</strong>.</p>
<form method="post" action="/oauth/authorize/verify-email-code">
  <input type="hidden" name="csrf" value="${escapeHtml(authRequest.csrfToken)}" />
  <label>Verification code
    <input name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="000000" minlength="6" required autofocus />
  </label>
  <button type="submit">Verify and continue</button>
</form>`,
    ),
    { "cache-control": "no-store" },
  )
}

export async function handleAuthorizeVerifyEmailCode(
  req: Request,
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)

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
    return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  }

  if (!authRequest.email || !authRequest.challengeToken) {
    return html(400, renderPage("Error", `<div class="error">Missing email challenge. Start over.</div>`))
  }

  const csrf = readParam(body, "csrf")
  const code = readParam(body, "code").trim()

  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }

  if (!code || code.length < 6) {
    return html(400, renderPage("Error", `<div class="error">Invalid code.</div>`))
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
      deviceName: "OAuth",
    })
    verifyResult = await verifyEmailCodeHandler(input, { ip: clientIp })
    if (!Value.Check(VerifyEmailCodeResponse, verifyResult)) {
      throw new Error("invalid verifyEmailCode response")
    }
  } catch (cause) {
    const response = html(401, renderPage("Error", `<div class="error">Code verification failed.</div>`))
    if (cause instanceof InlineError && cause.code < 500) {
      return response
    }
    throw new OAuthHandlerFailure(
      "OAuth email-code verification failed unexpectedly.",
      {
        cause: privateCause(cause),
        response,
      },
    )
  }

  return completeAuthorizeSignIn(authRequest, verifyResult, "email")
}

export async function handleAuthorizeSendSmsCode(
  req: Request,
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
  sendCode: typeof sendSmsCodeHandler = sendSmsCodeHandler,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:send-sms-code:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.sendSmsCode,
  })

  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many phone-code requests. Try again shortly.")
  }

  const authRequest = await getAuthRequestFromCookie(req)
  if (!authRequest) {
    return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  }

  const csrf = readParam(body, "csrf")
  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }
  const parsedPhoneNumber = parsePhoneNumber(readParam(body, "phone_number"))
  if (!parsedPhoneNumber?.isValid()) {
    return html(400, renderPage("Error", `<div class="error">Enter a valid phone number with country code.</div>`))
  }

  const phoneNumber = parsedPhoneNumber.number
  const phoneHash = await sha256Hex(phoneNumber)
  const perPhone = rateLimiter.consume({
    key: `oauth:abuse:send-sms:phone:${phoneHash}`,
    nowMs,
    rule: config.phoneAbuseRateLimits.sendPerPhone,
  })
  if (!perPhone.allowed) {
    return rateLimitedHtml(perPhone.retryAfterSeconds, "Too many attempts for this phone number. Try again later.")
  }

  const perContext = rateLimiter.consume({
    key: `oauth:abuse:send-sms:context:${phoneHash}:${normalizeRateLimitKeyPart(authRequest.clientId)}:${normalizeRateLimitKeyPart(authRequest.deviceId)}:${clientIp}`,
    nowMs,
    rule: config.phoneAbuseRateLimits.sendPerContext,
  })
  if (!perContext.allowed) {
    return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context. Try again later.")
  }

  let sendResult: unknown
  try {
    const input = Value.Decode(SendSmsCodeInput, {
      phoneNumber,
      deviceId: authRequest.deviceId,
      clientType: "web",
      deviceName: "OAuth",
    })
    sendResult = await sendCode(input, { ip: clientIp, source: "/oauth/authorize/send-sms-code" })
    if (!Value.Check(SendSmsCodeResponse, sendResult)) {
      throw new Error("invalid sendSmsCode response")
    }
  } catch (cause) {
    const response = html(502, renderPage("Error", `<div class="error">Failed to send code.</div>`))
    if (cause instanceof InlineError && cause.code < 500) {
      return response
    }
    throw new OAuthHandlerFailure(
      "OAuth phone-code delivery failed.",
      { cause: privateCause(cause), response },
    )
  }

  const normalizedPhoneNumber = String((sendResult as Record<string, unknown>)["phoneNumber"] ?? "")
  const formattedPhoneNumber = String((sendResult as Record<string, unknown>)["formattedPhoneNumber"] ?? phoneNumber)
  if (!normalizedPhoneNumber) {
    const response = html(500, renderPage("Error", `<div class="error">Login challenge unavailable.</div>`))
    throw new OAuthHandlerFailure(
      "OAuth phone-code delivery returned no phone number.",
      { cause: new Error("sendSmsCode returned no phone number"), response },
    )
  }

  await OauthModel.setAuthRequestPhoneNumber(authRequest.id, normalizedPhoneNumber)

  return html(
    200,
    renderPage(
      "Check your phone",
      `
<p class="intro">Enter the verification code sent to <strong>${escapeHtml(formattedPhoneNumber)}</strong>.</p>
<form method="post" action="/oauth/authorize/verify-sms-code">
  <input type="hidden" name="csrf" value="${escapeHtml(authRequest.csrfToken)}" />
  <label>Verification code
    <input name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="000000" minlength="6" required autofocus />
  </label>
  <button type="submit">Verify and continue</button>
</form>`,
    ),
    { "cache-control": "no-store" },
  )
}

export async function handleAuthorizeVerifySmsCode(
  req: Request,
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:verify-sms-code:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.verifySmsCode,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many verification attempts. Try again shortly.")
  }

  const authRequest = await getAuthRequestFromCookie(req)
  if (!authRequest) {
    return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  }
  if (!authRequest.phoneNumber) {
    return html(400, renderPage("Error", `<div class="error">Missing phone challenge. Start over.</div>`))
  }

  const csrf = readParam(body, "csrf")
  const code = readParam(body, "code").trim()
  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }
  if (!code || code.length < 6) {
    return html(400, renderPage("Error", `<div class="error">Invalid code.</div>`))
  }

  const phoneHash = await sha256Hex(authRequest.phoneNumber)
  const perPhone = rateLimiter.consume({
    key: `oauth:abuse:verify-sms:phone:${phoneHash}`,
    nowMs,
    rule: config.phoneAbuseRateLimits.verifyPerPhone,
  })
  if (!perPhone.allowed) {
    return rateLimitedHtml(perPhone.retryAfterSeconds, "Too many verification attempts for this phone number. Try again later.")
  }

  const perContext = rateLimiter.consume({
    key: `oauth:abuse:verify-sms:context:${phoneHash}:${normalizeRateLimitKeyPart(authRequest.clientId)}:${normalizeRateLimitKeyPart(authRequest.deviceId)}:${clientIp}`,
    nowMs,
    rule: config.phoneAbuseRateLimits.verifyPerContext,
  })
  if (!perContext.allowed) {
    return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context. Try again later.")
  }

  let verifyResult: unknown
  try {
    const input = Value.Decode(VerifySmsCodeInput, {
      phoneNumber: authRequest.phoneNumber,
      code,
      deviceId: authRequest.deviceId,
      clientType: "web",
      deviceName: "OAuth",
    })
    verifyResult = await verifySmsCodeHandler(input, { ip: clientIp })
    if (!Value.Check(VerifySmsCodeResponse, verifyResult)) {
      throw new Error("invalid verifySmsCode response")
    }
  } catch (cause) {
    const response = html(401, renderPage("Error", `<div class="error">Code verification failed.</div>`))
    if (cause instanceof InlineError && cause.code < 500) {
      return response
    }
    throw new OAuthHandlerFailure(
      "OAuth phone-code verification failed unexpectedly.",
      { cause: privateCause(cause), response },
    )
  }

  return completeAuthorizeSignIn(authRequest, verifyResult, "phone")
}

export async function handleAuthorizeConsent(req: Request, body: unknown): Promise<Response> {
  const authRequest = await getAuthRequestFromCookie(req)
  if (!authRequest) {
    return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  }

  if (!authRequest.inlineTokenEncrypted || !authRequest.inlineUserId) {
    return html(400, renderPage("Error", `<div class="error">Not signed in.</div>`))
  }

  const csrf = readParam(body, "csrf")
  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }

  const selectedSpaceIds = readAllParams(body, "space_id")
  const allowDms = readParam(body, "allow_dms") === "1"
  const allowHomeThreads = readParam(body, "allow_home_threads") === "1"

  if (selectedSpaceIds.length === 0 && !allowDms && !allowHomeThreads) {
    return html(400, renderPage("Error", `<div class="error">Select at least one space, DMs, or home threads.</div>`))
  }

  let token: string
  try {
    token = Encryption2.decryptToString(authRequest.inlineTokenEncrypted)
  } catch (cause) {
    const response = html(400, renderPage("Error", `<div class="error">Invalid session.</div>`))
    throw new OAuthHandlerFailure(
      "OAuth consent session decryption failed.",
      { cause, response },
    )
  }

  let availableSpaces: Array<{ id: number; name: string }> = []
  try {
    availableSpaces = await getSpacesForToken(token)
  } catch (cause) {
    const response = html(502, renderPage("Error", `<div class="error">Failed to load spaces.</div>`))
    throw new OAuthHandlerFailure(
      "OAuth consent space loading failed.",
      {
        cause: privateCause(cause),
        response,
      },
    )
  }

  const availableSpaceIdSet = new Set(availableSpaces.map((space) => String(space.id)))
  const chosenSpaceIds = selectedSpaceIds.filter((id) => availableSpaceIdSet.has(id)).map((id) => BigInt(id))

  if (chosenSpaceIds.length === 0 && !allowDms && !allowHomeThreads) {
    return html(400, renderPage("Error", `<div class="error">Invalid space selection.</div>`))
  }

  const nowMs = Date.now()
  const grantId = crypto.randomUUID()
  const grant = await OauthModel.createGrant({
    id: grantId,
    clientId: authRequest.clientId,
    inlineUserId: authRequest.inlineUserId,
    scope: authRequest.scope,
    resource: authRequest.resource,
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

export async function handleToken(
  req: Request,
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)

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
    const requestedResource = params["resource"]

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
    if (requestedResource != null && requestedResource !== grant.resource) {
      return json(400, { error: "invalid_target" })
    }

    const accessToken = createRandomToken("mcp_at")
    const accessHash = await sha256Hex(accessToken)
    const refreshToken = createRandomToken("mcp_rt")
    const refreshHash = await sha256Hex(refreshToken)

    const issued = await OauthModel.consumeAuthCodeAndCreateTokens({
      code,
      grantId: grant.id,
      nowMs,
      accessTokenHash: accessHash,
      accessTokenExpiresAtMs: nowMs + config.accessTokenTtlMs,
      refreshTokenHash: refreshHash,
      refreshTokenExpiresAtMs: nowMs + config.refreshTokenTtlMs,
    })
    if (!issued) return json(400, { error: "invalid_grant" })

    return json(
      200,
      {
        access_token: accessToken,
        refresh_token: refreshToken,
        token_type: "bearer",
        expires_in: Math.floor(config.accessTokenTtlMs / 1000),
        scope: grant.scope,
      },
      { "cache-control": "no-store", pragma: "no-cache" },
    )
  }

  if (grantType === "refresh_token") {
    const refreshToken = params["refresh_token"]
    const clientId = params["client_id"]
    const requestedResource = params["resource"]
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
    if (requestedResource != null && requestedResource !== result.grant.resource) {
      return json(400, { error: "invalid_target" })
    }

    const accessToken = createRandomToken("mcp_at")
    const accessHash = await sha256Hex(accessToken)

    const newRefreshToken = createRandomToken("mcp_rt")
    const newRefreshHash = await sha256Hex(newRefreshToken)

    const rotated = await OauthModel.rotateRefreshToken({
      currentTokenHash: refreshHash,
      replacementTokenHash: newRefreshHash,
      grantId: result.grant.id,
      nowMs,
      accessTokenHash: accessHash,
      accessTokenExpiresAtMs: nowMs + config.accessTokenTtlMs,
      refreshTokenExpiresAtMs: nowMs + config.refreshTokenTtlMs,
    })
    if (!rotated) return json(400, { error: "invalid_grant" })

    return json(
      200,
      {
        access_token: accessToken,
        refresh_token: newRefreshToken,
        token_type: "bearer",
        expires_in: Math.floor(config.accessTokenTtlMs / 1000),
        scope: result.grant.scope,
      },
      { "cache-control": "no-store", pragma: "no-cache" },
    )
  }

  return json(400, { error: "unsupported_grant_type" })
}

export async function handleRevoke(body: unknown): Promise<Response> {
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

export async function handleIntrospect(req: Request, body: unknown): Promise<Response> {
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
  } catch (cause) {
    const response = json(500, {
      error: "invalid_grant_session",
    })
    throw new OAuthHandlerFailure(
      "OAuth introspection session decryption failed.",
      { cause, response },
    )
  }

  return json(200, {
    active: true,
    grant_id: result.grant.id,
    client_id: result.grant.clientId,
    scope: result.grant.scope,
    aud: result.grant.resource,
    exp: Math.floor(result.accessToken.expiresAtMs / 1000),
    inline_user_id: String(result.grant.inlineUserId),
    space_ids: result.grant.spaceIds.map((spaceId) => spaceId.toString()),
    allow_dms: result.grant.allowDms,
    allow_home_threads: result.grant.allowHomeThreads,
    inline_token: inlineToken,
  })
}

export function handleAuthorizationServerMetadata(): Response {
  void OauthModel.cleanupExpired(Date.now()).catch((cause) => {
    Log.shared.error(
      "Failed to clean expired OAuth state",
      cause,
    )
  })

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
}

export function prepareAuthorizeRequest(request: Request): Promise<Response> {
  void OauthModel.cleanupExpired(Date.now()).catch((cause) => {
    Log.shared.error(
      "Failed to clean expired OAuth state",
      cause,
    )
  })
  return handleAuthorizeGet(new URL(request.url))
}
