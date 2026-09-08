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
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { Value } from "@sinclair/typebox/value"
import { randomBytes, timingSafeEqual } from "node:crypto"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { OAuthHandlerFailure } from "./httpHandlerFailure"
import parsePhoneNumber from "libphonenumber-js"
import { db } from "@in/server/db"
import { members, sessions, spaces, users, userNotDeleted, type DbProviderAuthAttempt } from "@in/server/db/schema"
import { and, eq, isNull, ne, or } from "drizzle-orm"
import { ProviderAuthModel } from "@in/server/db/models/providerAuth"
import {
  attachProviderAfterEmailProof,
  beginNativeAppleAuth,
  beginProviderAuth,
  callbackFailureContext,
  claimProviderEmailAttempt,
  completeProviderCallback,
  completeNativeAppleAuth,
  continueProviderWithInvite,
  issueAppTicket,
  hashProviderSecret,
  redeemProviderTicket,
  requireProviderEmailAttempt,
  restoreProviderEmailAttempt,
  supportedAppCallbackScheme,
  ProviderCallbackCompletionError,
  type ProviderCallbackFailureContext,
  type ProviderLoginResult,
} from "@in/server/modules/auth/provider/service"
import {
  completionResponse,
  requireHostedLoginTransaction,
} from "@in/server/modules/auth/hostedLogin/httpHandlers"
import { beginOAuthHostedLogin, completeHostedLogin } from "@in/server/modules/auth/hostedLogin/service"
import { verifyEmailAccountProof } from "@in/server/modules/auth/contactProof"
import { isValidAppCodeChallenge } from "@in/server/modules/auth/provider/appHandoff"
import {
  authRequestCookieHeader,
  authRequestCookieName,
} from "./authRequestCookie"
import { normalizeMcpResourceIndicator } from "./resourceIndicator"
import { isGrantSessionActive } from "./grantSession"
import { needsOAuthProfile, parseOAuthProfile, type OAuthProfile } from "./profile"
import { oauthClientKind } from "./clientKind"
import { handler as updateProfile } from "@in/server/methods/updateProfile"

const config = oauthConfig()
// TODO(effect-cutover): remove this oracle-only limiter with legacyServer.ts
// after the post-cutover differential window. Production injects a separately
// scoped limiter through its Effect Layer.
const legacyRateLimiter = new InMemoryRateLimiter()
const PROVIDER_CLEANUP_INTERVAL_MS = 60_000
const PROVIDER_CLEANUP_BATCH_SIZE = 250
const PROVIDER_EMAIL_ATTEMPT_COOLDOWN = { max: 1, windowMs: 45_000 } as const
const PROVIDER_EMAIL_ATTEMPT_LIMIT = { max: 3, windowMs: 15 * 60_000 } as const
const PROVIDER_EMAIL_VERIFY_ATTEMPT_LIMIT = { max: 10, windowMs: 15 * 60_000 } as const
const PROVIDER_INVITE_ATTEMPT_LIMIT = { max: 5, windowMs: 15 * 60_000 } as const
const PROVIDER_CLIENT_METADATA_LIMITS = [
  ["device_id", 128],
  ["client_version", 64],
  ["os_version", 64],
  ["device_name", 256],
  ["timezone", 64],
] as const
const NATIVE_PROVIDER_CLIENT_METADATA_LIMITS = [
  ["deviceId", 128],
  ["clientVersion", 64],
  ["osVersion", 64],
  ["deviceName", 256],
  ["timezone", 64],
] as const
let nextProviderCleanupAtMs = 0
let providerCleanupInFlight: Promise<void> | undefined

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
    input[type="text"], input[type="email"], input[type="tel"], input[name="code"] { width: 100%; min-height: 46px; padding: 11px 13px; margin-top: 7px; border-radius: 10px; border: 1px solid #cececa; background: #fff; color: #171717; font: inherit; font-size: 15px; outline: none; transition: border-color 120ms ease, box-shadow 120ms ease; }
    input[type="text"]:focus, input[type="email"]:focus, input[type="tel"]:focus, input[name="code"]:focus { border-color: #343431; box-shadow: 0 0 0 3px rgba(30, 30, 28, 0.1); }
    input[name="code"] { letter-spacing: 0.16em; font-variant-numeric: tabular-nums; }
    button { width: 100%; min-height: 46px; margin-top: 20px; padding: 11px 16px; border-radius: 11px; border: 1px solid #171717; background: #171717; color: #fff; font: inherit; font-size: 14px; font-weight: 650; cursor: pointer; transition: background 120ms ease, transform 120ms ease; }
    button:hover { background: #30302d; }
    button:active { transform: translateY(1px); }
    .provider-methods { display: grid; gap: 9px; margin-bottom: 20px; }
    .provider-button { display: flex; align-items: center; justify-content: center; gap: 10px; width: 100%; min-height: 46px; padding: 11px 16px; border: 1px solid #cececa; border-radius: 11px; background: #fff; color: #171717; font-size: 14px; font-weight: 650; text-decoration: none; }
    .provider-button:hover { background: #f5f5f2; }
    .provider-mark { display: inline-grid; width: 18px; height: 18px; place-items: center; font-size: 18px; line-height: 1; text-align: center; }
    .provider-mark svg { display: block; width: 18px; height: 18px; }
    .divider { display: flex; align-items: center; gap: 10px; margin: 18px 0; color: #8a8a84; font-size: 12px; }
    .divider::before, .divider::after { content: ""; height: 1px; flex: 1; background: #e5e5e1; }
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
    .status { display: grid; justify-items: center; gap: 14px; text-align: center; }
    .status .intro { margin: 0; max-width: 320px; }
    .spinner { width: 24px; height: 24px; border: 2px solid #deded9; border-top-color: #292925; border-radius: 50%; animation: spin 800ms linear infinite; }
    .actions { display: grid; width: 100%; gap: 9px; margin-top: 8px; }
    .action { display: grid; width: 100%; min-height: 46px; place-items: center; padding: 11px 16px; border: 1px solid #171717; border-radius: 11px; background: #171717; color: #fff; font-size: 14px; font-weight: 650; text-decoration: none; cursor: pointer; }
    .action.secondary { border-color: #cececa; background: transparent; color: #171717; }
    .app-downloads { margin: 20px 0; }
    .app-downloads h2 { margin: 0; font-size: 15px; }
    .app-downloads p { margin: 10px 0 0; font-size: 13px; line-height: 1.5; }
    .app-downloads a { color: inherit; text-underline-offset: 3px; }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (max-width: 520px) { body { align-items: start; padding: 22px 14px; } .brand { margin-bottom: 18px; } .card { padding: 24px 20px; border-radius: 16px; } }
    @media (prefers-color-scheme: dark) {
      body { color: #f3f3f0; background: #111210; }
      .card { border-color: #343532; background: #1b1c19; box-shadow: none; }
      .intro, .muted { color: #a7a8a1; }
      input[type="text"], input[type="email"], input[type="tel"], input[name="code"] { border-color: #464742; background: #22231f; color: #f3f3f0; }
      input[type="text"]:focus, input[type="email"]:focus, input[type="tel"]:focus, input[name="code"]:focus { border-color: #d0d0ca; box-shadow: 0 0 0 3px rgba(240, 240, 235, 0.1); }
      button { border-color: #f1f1ed; background: #f1f1ed; color: #181916; }
      button:hover { background: #dcdcd7; }
      .provider-button { border-color: #464742; background: #22231f; color: #f3f3f0; }
      .provider-button:hover { background: #30312d; }
      .divider::before, .divider::after { background: #363732; }
      .method-tabs { background: #252622; }
      .method-tabs label { color: #a1a29b; }
      .method-tabs label:has(input:checked) { background: #3a3b36; color: #f3f3f0; box-shadow: none; }
      .scope { border-color: #363732; background: #21221f; }
      .spaces label { border-color: #30312d; }
      .spaces input { accent-color: #f1f1ed; }
      code { background: #30312d; }
      .error { border-color: #663e39; background: #2d1d1b; color: #f1aaa2; }
      .trust { color: #878881; }
      .spinner { border-color: #42433e; border-top-color: #f1f1ed; }
      .action { border-color: #f1f1ed; background: #f1f1ed; color: #181916; }
      .action.secondary { border-color: #464742; background: transparent; color: #f3f3f0; }
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

function jsonForInlineScript(value: string): string {
  return JSON.stringify(value).replaceAll("<", "\\u003c")
}

function providerBrowserPage(input: {
  title: string
  description?: string
  appUrl?: string
  openingLabel?: string
  status?: number
}): Response {
  const nonce = randomBytes(18).toString("base64")
  const favicon = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 54 54'%3E%3Crect x='5' y='5' width='44' height='44' rx='16' fill='none' stroke='%23171717' stroke-width='10'/%3E%3Crect x='17' y='17' width='10' height='20' rx='4' fill='%23171717'/%3E%3C/svg%3E"
  const appAction = input.appUrl
    ? `<a class="action" id="open-inline" href="${escapeHtml(input.appUrl)}">Open Inline</a>`
    : ""
  const openingStatus = input.appUrl
    ? `<div class="opening" id="opening-status" role="status">
        <span class="spinner" id="opening-spinner" aria-hidden="true"></span>
        <span id="opening-label">${escapeHtml(input.openingLabel ?? "Opening Inline…")}</span>
      </div>`
    : ""
  const description = input.description
    ? `<p class="description">${escapeHtml(input.description)}</p>`
    : ""
  const appOpenScript = input.appUrl
    ? `window.addEventListener("load",function(){
  window.location.assign(${jsonForInlineScript(input.appUrl)});
  window.setTimeout(function(){
    document.getElementById("opening-spinner")?.setAttribute("hidden","");
    const label=document.getElementById("opening-label");
    if(label)label.textContent="Inline is ready to open.";
  },1200);
});`
    : ""
  const body = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="light dark" />
  <title>${escapeHtml(input.title)} · Inline</title>
  <link rel="icon" href="${favicon}" />
  <style>
    * { box-sizing: border-box; }
    html, body { min-height: 100%; }
    body { margin: 0; color: #171717; background: #fafaf8; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    main { min-height: 100vh; display: grid; grid-template-rows: 1fr auto; padding: 32px 20px 20px; }
    .content { align-self: center; display: grid; justify-items: center; gap: 18px; width: min(100%, 360px); margin: 0 auto; text-align: center; }
    .mark { width: 34px; height: 34px; }
    h1 { margin: 2px 0 0; font-size: 26px; font-weight: 600; letter-spacing: -0.02em; }
    .description, .opening, footer { color: #81817b; font-size: 14px; font-weight: 400; line-height: 1.5; }
    .description { max-width: 330px; margin: -5px 0 0; }
    .opening { display: inline-flex; align-items: center; justify-content: center; gap: 8px; min-height: 22px; }
    .spinner { width: 15px; height: 15px; border: 1.5px solid #d5d5d0; border-top-color: #555550; border-radius: 50%; animation: spin 750ms linear infinite; }
    .spinner[hidden] { display: none; }
    .action { display: inline-flex; min-width: 210px; min-height: 40px; align-items: center; justify-content: center; padding: 0 18px; border-radius: 10px; background: #000; color: #fff; font-size: 15px; font-weight: 500; text-decoration: none; transition: opacity 150ms ease, transform 150ms ease; }
    .action:hover { opacity: .82; }
    .action:active { transform: scale(.98); }
    footer { align-self: end; padding-top: 28px; text-align: center; font-size: 12px; color: #aaa9a4; }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (prefers-color-scheme: dark) {
      body { color: #f3f3f0; background: #111210; }
      .mark { color: #f3f3f0; }
      .description, .opening { color: #a7a8a1; }
      .spinner { border-color: #42433e; border-top-color: #d7d7d2; }
      .action { background: rgba(255,255,255,.92); color: #111210; }
      footer { color: #777872; }
    }
    @media (max-width: 520px) { main { padding: 24px 18px 18px; } h1 { font-size: 24px; } }
    @media (prefers-reduced-motion: reduce) { .spinner { animation-duration: 1500ms; } .action { transition: none; } }
  </style>
</head>
<body>
  <main>
    <section class="content">
      <svg class="mark" viewBox="0 0 54 54" fill="none" aria-label="Inline"><rect x="5" y="5" width="44" height="44" rx="16" stroke="currentColor" stroke-width="10"/><rect x="17" y="17" width="10" height="20" rx="4" fill="currentColor"/></svg>
      <h1>${escapeHtml(input.title)}</h1>
      ${description}
      ${openingStatus}
      ${appAction}
    </section>
    <footer>You can close this window after Inline opens.</footer>
  </main>
<script nonce="${nonce}">
${appOpenScript}
</script>
</body>
</html>`

  return html(input.status ?? 200, body, {
    "cache-control": "no-store",
    "content-security-policy": `default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'nonce-${nonce}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  })
}

export function providerAppHandoffResponse(appUrl: string): Response {
  return providerBrowserPage({
    title: "Sign-in successful",
    appUrl,
    openingLabel: "Opening Inline…",
  })
}

export function providerAppErrorResponse(input: {
  appUrl?: string
  title: string
  description: string
}): Response {
  return providerBrowserPage({
    ...input,
    openingLabel: input.appUrl ? "Returning to Inline…" : undefined,
    status: 400,
  })
}

async function providerBrowserError(input: {
  state?: string
  context?: ProviderCallbackFailureContext
  code: "cancelled" | "failed"
  title: string
  description: string
}): Promise<Response> {
  let appUrl: string | undefined
  let context = input.context
  if (!context && input.state) {
    const attempt = await ProviderAuthModel.getActiveByStateHash(
      hashProviderSecret(input.state),
    ).catch(() => undefined)
    if (attempt) context = callbackFailureContext(attempt)
  }
  if (context) {
    if (context.purpose === "app" && context.appCallbackScheme) {
      const callback = new URL(`${context.appCallbackScheme}://auth/provider`)
      callback.searchParams.set("error", input.code)
      if (context.appCodeChallenge) callback.searchParams.set("code_challenge", context.appCodeChallenge)
      appUrl = callback.toString()
    }
    await closeProviderAttemptAfterFailure(context)
  }
  return providerAppErrorResponse({
    appUrl,
    title: input.title,
    description: input.description,
  })
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

function nativeAuthJson(status: number, body: unknown, headers?: HeadersInit): Response {
  const response = json(status, body, headers)
  response.headers.set("cache-control", "no-store")
  return response
}

function html(status: number, body: string, headers?: HeadersInit): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
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
  const id = parseCookie(req, authRequestCookieName(config))
  if (!id) return null
  return await OauthModel.getAuthRequest(id, Date.now())
}

async function getSpacesForUser(userId: number): Promise<Array<{ id: number; name: string }>> {
  const rows = await db.select({ id: spaces.id, name: spaces.name }).from(members).innerJoin(
    spaces,
    and(eq(spaces.id, members.spaceId), isNull(spaces.deleted)),
  ).where(eq(members.userId, userId))
  return rows
}

function oauthProfilePage(
  authRequest: OauthAuthRequest,
  user: OAuthProfile,
  error?: string,
  values?: { name: string; username: string },
): Response {
  const name = values?.name ?? [user.firstName, user.lastName].filter(Boolean).join(" ")
  const username = values?.username ?? user.username ?? ""
  return html(error ? 400 : 200, renderPage("Set up your profile", `
<p class="intro">Choose how you appear in Inline. Then continue connecting your app.</p>
${error ? `<div class="error" role="alert">${escapeHtml(error)}</div>` : ""}
<form method="post" action="/oauth/authorize/consent">
  <input type="hidden" name="csrf" value="${escapeHtml(authRequest.csrfToken)}" />
  <input type="hidden" name="step" value="profile" />
  <label for="profile-name">Name</label>
  <input type="text" id="profile-name" name="name" autocomplete="name" value="${escapeHtml(name)}" maxlength="513" required autofocus />
  <label for="profile-username">Username</label>
  <input type="text" id="profile-username" name="username" autocomplete="username" autocapitalize="none" spellcheck="false" value="${escapeHtml(username)}" minlength="2" maxlength="256" required />
  <button type="submit">Continue</button>
</form>`), { "cache-control": "no-store" })
}

async function loadOAuthProfile(userId: number) {
  return (await db.select({
    firstName: users.firstName, lastName: users.lastName, username: users.username,
    pendingSetup: users.pendingSetup,
  }).from(users).where(and(eq(users.id, userId), userNotDeleted())).limit(1))[0]
}

export async function completeAuthorizeSignIn(
  authRequest: OauthAuthRequest,
  verifyResult: unknown,
  method: "email" | "phone" | "google" | "apple",
): Promise<Response> {
  const token = String((verifyResult as Record<string, unknown>)["token"] ?? "")
  const userId = Number((verifyResult as Record<string, unknown>)["userId"] ?? 0)

  if (!Number.isInteger(userId) || userId <= 0) {
    const response = html(500, renderPage("Error", `<div class="error">Invalid login session.</div>`))
    throw new OAuthHandlerFailure(
      `OAuth ${method} verification returned an invalid login session.`,
      {
        cause: new Error(`${method} verification returned an invalid login session`),
        response,
      },
    )
  }

  let encryptedToken: Buffer | undefined
  try {
    encryptedToken = token ? Encryption2.encrypt(Buffer.from(token, "utf8")) : undefined
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
    authMethod: method,
  })

  const profile = await loadOAuthProfile(userId)
  if (!profile) return html(401, renderPage("Sign-in expired", `<div class="error">Sign in again to continue.</div>`))
  if (needsOAuthProfile(profile)) return oauthProfilePage(authRequest, profile)

  let spaces: Array<{ id: number; name: string }> = []
  try {
    spaces = await getSpacesForUser(userId)
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
  const priorSession = oauthClientKind(client?.clientName) === "chatgpt"
    ? (await db.select({ id: sessions.id }).from(sessions).where(and(
      eq(sessions.userId, userId),
      or(isNull(sessions.deviceId), ne(sessions.deviceId, authRequest.deviceId)),
    )).limit(1))[0]
    : true
  const downloadPrompt = !priorSession ? `
<section class="scope app-downloads" aria-label="Get Inline">
  <h2>Get Inline on your devices</h2>
  <p>Download Inline for macOS or iOS to start conversations and connect with your team. Sign in with the same account.</p>
  <p><a href="https://inline.chat/download/mac/beta" target="_blank" rel="noopener noreferrer">Download for macOS</a> · <a href="https://testflight.apple.com/join/FkC3f7fz" target="_blank" rel="noopener noreferrer">Get Inline for iOS</a></p>
  <p class="muted">You can download the apps later. Continue below to connect ChatGPT.</p>
</section>` : ""

  return html(
    200,
    renderPage(
      "Choose what to share",
      `
${downloadPrompt}
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

export async function handleAuthorizeContinue(req: Request): Promise<Response> {
  const authRequest = await getAuthRequestFromCookie(req)
  if (!authRequest?.inlineUserId || !authRequest.authMethod) {
    return html(400, renderPage("Error", `<div class="error">Sign-in expired. Please try again.</div>`))
  }
  return completeAuthorizeSignIn(
    authRequest,
    { userId: authRequest.inlineUserId },
    authRequest.authMethod,
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
  const resource = normalizeMcpResourceIndicator(requestedResource, config.resource)
  if (!resource) {
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
    resource,
    codeChallenge,
    csrfToken,
    deviceId,
    nowMs,
    expiresAtMs: nowMs + config.authRequestTtlMs,
  })

  const login = await beginOAuthHostedLogin({
    oauthAuthRequestId: authRequestId,
    client: { clientType: "web", deviceId, deviceName: client.clientName ?? "OAuth" },
  })
  return new Response(null, {
    status: 303,
    headers: {
      location: login.browserUrl,
      "set-cookie": authRequestCookieHeader(config, authRequestId),
      "cache-control": "no-store",
    },
  })
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

  if (!authRequest.inlineUserId || !authRequest.inlineTokenEncrypted?.length) {
    return html(400, renderPage("Error", `<div class="error">Not signed in.</div>`))
  }

  const csrf = readParam(body, "csrf")
  if (!constantTimeEqual(csrf, authRequest.csrfToken)) {
    return html(400, renderPage("Error", `<div class="error">Invalid CSRF token.</div>`))
  }

  const profile = await loadOAuthProfile(authRequest.inlineUserId)
  if (!profile) return html(401, renderPage("Sign-in expired", `<div class="error">Sign in again to continue.</div>`))
  if (needsOAuthProfile(profile)) {
    if (readParam(body, "step") !== "profile") return oauthProfilePage(authRequest, profile)
    const values = { name: readParam(body, "name"), username: readParam(body, "username") }
    const parsed = parseOAuthProfile(values.name, values.username)
    if (parsed.error) return oauthProfilePage(authRequest, profile, parsed.error, values)
    const session = (await db.select({ id: sessions.id }).from(sessions).where(and(
      eq(sessions.userId, authRequest.inlineUserId), eq(sessions.deviceId, authRequest.deviceId), isNull(sessions.revoked),
    )).limit(1))[0]
    if (!session) return html(401, renderPage("Sign-in expired", `<div class="error">Sign in again to continue.</div>`))
    try {
      await updateProfile(parsed.profile, { currentUserId: authRequest.inlineUserId, currentSessionId: session.id, ip: undefined })
    } catch (cause) {
      if (cause instanceof InlineError && cause.code === 400) {
        return oauthProfilePage(authRequest, profile, cause.description ?? "Check your name and username.", values)
      }
      throw cause
    }
    return completeAuthorizeSignIn(authRequest, { userId: authRequest.inlineUserId }, authRequest.authMethod ?? "email")
  }
  // A retried profile POST must never double as consent.
  if (readParam(body, "step") === "profile") {
    return completeAuthorizeSignIn(authRequest, { userId: authRequest.inlineUserId }, authRequest.authMethod ?? "email")
  }

  const selectedSpaceIds = readAllParams(body, "space_id")
  const allowDms = readParam(body, "allow_dms") === "1"
  const allowHomeThreads = readParam(body, "allow_home_threads") === "1"

  if (selectedSpaceIds.length === 0 && !allowDms && !allowHomeThreads) {
    return html(400, renderPage("Error", `<div class="error">Select at least one space, DMs, or home threads.</div>`))
  }

  let availableSpaces: Array<{ id: number; name: string }> = []
  try {
    availableSpaces = await getSpacesForUser(authRequest.inlineUserId)
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
  const authCode = createRandomToken("mcp_ac")
  const userId = authRequest.inlineUserId
  const consumed = await db.transaction(async (tx) => {
    // Consent is single-use, just like its authorization code. Consumption and
    // issuance share a transaction so a failed insert remains safely retryable.
    const request = await OauthModel.consumeAuthRequest(authRequest.id, userId, nowMs, tx)
    if (!request) return null
    const grant = await OauthModel.createGrant({
      id: grantId,
      clientId: request.clientId,
      inlineUserId: userId,
      scope: request.scope,
      resource: request.resource,
      spaceIds: chosenSpaceIds,
      allowDms,
      allowHomeThreads,
      inlineTokenEncrypted: request.inlineTokenEncrypted,
      nowMs,
    }, tx)
    await OauthModel.createAuthCode({
      code: authCode,
      grantId: grant.id,
      clientId: grant.clientId,
      redirectUri: request.redirectUri,
      codeChallenge: request.codeChallenge,
      nowMs,
      expiresAtMs: nowMs + config.authCodeTtlMs,
    }, tx)
    return request
  })

  if (!consumed) {
    return html(400, renderPage("Error", `<div class="error">Session expired. Please try again.</div>`))
  }

  const redirect = new URL(consumed.redirectUri)
  redirect.searchParams.set("code", authCode)
  redirect.searchParams.set("state", consumed.state)

  return new Response(null, {
    status: 302,
    headers: {
      location: redirect.toString(),
      "set-cookie": authRequestCookieHeader(config, "", { maxAgeSeconds: 0 }),
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
    if (!normalizeMcpResourceIndicator(requestedResource, grant.resource)) {
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
    if (!normalizeMcpResourceIndicator(requestedResource, result.grant.resource)) {
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

  if (!result.grant.inlineTokenEncrypted) {
    return json(500, { error: "invalid_grant_session" })
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

  if (!await isGrantSessionActive(inlineToken, result.grant.inlineUserId)) {
    return json(401, { active: false })
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

export async function handleProviderStart(
  request: Request,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-start:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.providerStart,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many sign-in attempts. Try again shortly.")
  }

  const url = new URL(request.url)
  const provider = url.searchParams.get("provider")
  const purpose = url.searchParams.get("purpose")
  if ((provider !== "google" && provider !== "apple") ||
    (purpose !== "app" && purpose !== "mcp_oauth" && purpose !== "hosted_login")) {
    return html(400, renderPage("Sign-in error", `<div class="error">Invalid sign-in request.</div>`))
  }
  for (const [name, limit] of PROVIDER_CLIENT_METADATA_LIMITS) {
    if ((url.searchParams.get(name)?.length ?? 0) > limit) {
      return html(400, renderPage("Sign-in error", `<div class="error">Invalid sign-in request.</div>`))
    }
  }
  scheduleProviderCleanup(nowMs)

  try {
    if (purpose === "hosted_login") {
      const transaction = await requireHostedLoginTransaction(request)
      if (!transaction) {
        return html(400, renderPage("Sign-in expired", `<div class="error">Start the sign-in again.</div>`))
      }
      const providerUrl = await beginProviderAuth({
        provider,
        purpose,
        loginTransactionId: transaction.id,
        client: { ...transaction.client, clientType: "web", deviceName: "Hosted login" },
      })
      return new Response(null, { status: 302, headers: { location: providerUrl.toString(), "cache-control": "no-store" } })
    }
    if (purpose === "mcp_oauth") {
      const authRequest = await getAuthRequestFromCookie(request)
      if (!authRequest) {
        return html(400, renderPage("Sign-in expired", `<div class="error">Start the connected-app sign-in again.</div>`))
      }
      const providerUrl = await beginProviderAuth({
        provider,
        purpose,
        oauthAuthRequestId: authRequest.id,
        client: { clientType: "web", deviceId: authRequest.deviceId, deviceName: "OAuth" },
      })
      return new Response(null, { status: 302, headers: { location: providerUrl.toString(), "cache-control": "no-store" } })
    }

    const callbackScheme = url.searchParams.get("callback_scheme")
    if (!supportedAppCallbackScheme(callbackScheme)) {
      return html(400, renderPage("Sign-in error", `<div class="error">This Inline app callback is not allowed.</div>`))
    }
    const clientType = url.searchParams.get("client_type")
    if (clientType !== "ios" && clientType !== "macos") {
      return html(400, renderPage("Sign-in error", `<div class="error">This client is not supported.</div>`))
    }
    const appCodeChallenge = url.searchParams.get("code_challenge")
    if (!isValidAppCodeChallenge(appCodeChallenge)) {
      return html(400, renderPage("Sign-in error", `<div class="error">This sign-in request is not securely bound to the app.</div>`))
    }
    const providerUrl = await beginProviderAuth({
      provider,
      purpose,
      appCallbackScheme: callbackScheme,
      appCodeChallenge,
      client: {
        clientType,
        deviceId: url.searchParams.get("device_id") || undefined,
        clientVersion: url.searchParams.get("client_version") || undefined,
        osVersion: url.searchParams.get("os_version") || undefined,
        deviceName: url.searchParams.get("device_name") || undefined,
        timezone: url.searchParams.get("timezone") || undefined,
      },
    })
    return new Response(null, { status: 302, headers: { location: providerUrl.toString(), "cache-control": "no-store" } })
  } catch (cause) {
    Log.shared.error("Failed to begin provider sign-in", { provider, purpose, cause })
    return html(503, renderPage("Sign-in unavailable", `<div class="error">This sign-in method is not available right now.</div>`))
  }
}

export async function handleNativeAppleStart(
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-native-apple-start:${resolveClientIp(clientIpOverride)}`,
    nowMs,
    rule: config.endpointRateLimits.providerStart,
  })
  if (!endpointRate.allowed) {
    return nativeAuthJson(429, {
      ok: false,
      error: "RATE_LIMITED",
      description: "Too many sign-in attempts. Try again shortly.",
    }, { "retry-after": String(endpointRate.retryAfterSeconds) })
  }
  for (const [name, limit] of NATIVE_PROVIDER_CLIENT_METADATA_LIMITS) {
    if (readParam(body, name).length > limit) {
      return nativeAuthJson(400, { ok: false, error: "INVALID_REQUEST", description: "Invalid client metadata." })
    }
  }
  const callbackScheme = readParam(body, "callbackScheme")
  const codeChallenge = readParam(body, "codeChallenge")
  const clientType = readParam(body, "clientType")
  if (
    !supportedAppCallbackScheme(callbackScheme) ||
    !isValidAppCodeChallenge(codeChallenge) ||
    clientType !== "ios"
  ) {
    return nativeAuthJson(400, {
      ok: false,
      error: "INVALID_REQUEST",
      description: "This native sign-in request is not securely bound to a supported Inline app.",
    })
  }
  scheduleProviderCleanup(nowMs)

  try {
    const result = await beginNativeAppleAuth({
      appCallbackScheme: callbackScheme,
      appCodeChallenge: codeChallenge,
      client: {
        clientType,
        deviceId: readParam(body, "deviceId") || undefined,
        clientVersion: readParam(body, "clientVersion") || undefined,
        osVersion: readParam(body, "osVersion") || undefined,
        deviceName: readParam(body, "deviceName") || undefined,
        timezone: readParam(body, "timezone") || undefined,
      },
    })
    return nativeAuthJson(200, { ok: true, result })
  } catch (cause) {
    Log.shared.error("Failed to begin native Apple sign-in", { cause })
    return nativeAuthJson(503, {
      ok: false,
      error: "PROVIDER_UNAVAILABLE",
      description: "Apple Sign-In is not available right now.",
    })
  }
}

export async function handleNativeAppleComplete(
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const callbackRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-native-apple-complete:${resolveClientIp(clientIpOverride)}`,
    nowMs: Date.now(),
    rule: config.endpointRateLimits.providerCallback,
  })
  if (!callbackRate.allowed) {
    return nativeAuthJson(429, {
      ok: false,
      error: "RATE_LIMITED",
      description: "Too many sign-in completions. Try again shortly.",
    }, { "retry-after": String(callbackRate.retryAfterSeconds) })
  }
  const state = readParam(body, "state")
  const code = readParam(body, "authorizationCode")
  const identityToken = readParam(body, "identityToken")
  const firstName = readParam(body, "firstName") || undefined
  const lastName = readParam(body, "lastName") || undefined
  if (
    !state || state.length > 256 ||
    !code || code.length > 4_096 ||
    !identityToken || identityToken.length > 32_768 ||
    (firstName?.length ?? 0) > 256 ||
    (lastName?.length ?? 0) > 256
  ) {
    return nativeAuthJson(400, { ok: false, error: "INVALID_REQUEST", description: "Invalid Apple credential." })
  }

  let completionContext: ProviderCallbackFailureContext | undefined
  try {
    const outcome = await completeNativeAppleAuth({ state, code, identityToken, firstName, lastName })
    completionContext = callbackFailureContext(outcome.attempt)
    if (outcome.kind === "login") {
      const ticket = await issueAppTicket(outcome.attempt)
      return nativeAuthJson(200, { ok: true, result: { kind: "complete", ticket } })
    }
    if (outcome.kind === "invite") {
      return nativeAuthJson(200, {
        ok: true,
        result: {
          kind: "inviteRequired",
          attemptId: outcome.attempt.id,
          continuation: outcome.continuation,
        },
      })
    }
    throw new Error("Apple did not provide an authoritative email address")
  } catch (cause) {
    const failureContext = cause instanceof ProviderCallbackCompletionError
      ? cause.context
      : completionContext
    if (failureContext) {
      await closeProviderAttemptAfterFailure(failureContext)
    }
    Log.shared.error("Native Apple sign-in completion failed", {
      cause: cause instanceof ProviderCallbackCompletionError ? cause.cause : cause,
    })
    return nativeAuthJson(400, {
      ok: false,
      error: "APPLE_SIGN_IN_FAILED",
      description: "Apple Sign-In could not be verified. Please try again.",
    })
  }
}

async function closeProviderAttemptAfterFailure(
  context: ProviderCallbackFailureContext,
): Promise<void> {
  await ProviderAuthModel.update(context.id, {
    status: "used",
    usedAt: new Date(),
  }).catch((cause) => {
    Log.shared.error("Failed to close provider attempt after callback error", {
      provider: context.provider,
      cause,
    })
  })
}

export async function handleNativeAppleContinueInvite(
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-native-apple-invite:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.providerContinueInvite,
  })
  if (!endpointRate.allowed) {
    return nativeAuthJson(429, {
      ok: false,
      error: "RATE_LIMITED",
      description: "Too many invite attempts. Try again shortly.",
    }, { "retry-after": String(endpointRate.retryAfterSeconds) })
  }
  const attemptId = readParam(body, "attemptId")
  const continuation = readParam(body, "continuation")
  const inviteCode = readParam(body, "inviteCode")
  if (
    !attemptId || attemptId.length > 128 ||
    !continuation || continuation.length > 256 ||
    !inviteCode || inviteCode.length > 64
  ) {
    return nativeAuthJson(400, {
      ok: false,
      error: "INVALID_REQUEST",
      description: "Invalid Apple invite continuation.",
    })
  }
  const attemptRate = rateLimiter.consume({
    key: `oauth:abuse:provider-native-apple-invite:attempt:${normalizeRateLimitKeyPart(attemptId)}`,
    nowMs,
    rule: PROVIDER_INVITE_ATTEMPT_LIMIT,
  })
  if (!attemptRate.allowed) {
    return nativeAuthJson(429, {
      ok: false,
      error: "RATE_LIMITED",
      description: "Too many invite attempts for this sign-in.",
    }, { "retry-after": String(attemptRate.retryAfterSeconds) })
  }
  try {
    const outcome = await continueProviderWithInvite({
      attemptId,
      continuation,
      inviteCode,
    })
    const ticket = await issueAppTicket(outcome.attempt)
    return nativeAuthJson(200, { ok: true, result: { ticket } })
  } catch (cause) {
    const description = cause instanceof InlineError
      ? cause.description ?? "Invalid invite code."
      : "The invite code could not be accepted."
    return nativeAuthJson(400, { ok: false, error: "INVITE_CODE_INVALID", description })
  }
}

export async function handleProviderCallback(
  provider: "google" | "apple",
  request: Request,
  body?: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const callbackRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-callback:${resolveClientIp(clientIpOverride)}`,
    nowMs,
    rule: config.endpointRateLimits.providerCallback,
  })
  if (!callbackRate.allowed) {
    return rateLimitedHtml(callbackRate.retryAfterSeconds, "Too many sign-in callbacks. Try again shortly.")
  }

  const url = new URL(request.url)
  const state = provider === "google" ? url.searchParams.get("state") ?? "" : readParam(body, "state")
  const code = provider === "google" ? url.searchParams.get("code") ?? "" : readParam(body, "code")
  const error = provider === "google" ? url.searchParams.get("error") : readParam(body, "error")
  if (error) {
    return providerBrowserError({
      state,
      code: "cancelled",
      title: "Sign-in cancelled",
      description: "No changes were made. Return to Inline when you are ready.",
    })
  }
  if (!state || !code) {
    return providerBrowserError({
      state,
      code: "failed",
      title: "Sign-in could not finish",
      description: "Return to Inline and try signing in again.",
    })
  }

  let context: ProviderCallbackFailureContext | undefined
  try {
    const outcome = await completeProviderCallback({
      provider,
      state,
      code,
      idTokenFromAuthorization: provider === "apple" ? readParam(body, "id_token") : undefined,
      appleUserJson: provider === "apple" ? readParam(body, "user") : undefined,
    })
    context = callbackFailureContext(outcome.attempt)
    if (outcome.kind === "login") {
      return finishProviderBrowserLogin(outcome.attempt, outcome.result)
    }
    if (outcome.kind === "invite") {
      return html(200, renderPage("Enter your invite code", `
<p class="intro">Your provider account is verified. Enter an Inline invite code to create your account.</p>
<form method="post" action="/v1/auth/provider/continue-invite">
  <input type="hidden" name="attempt_id" value="${escapeHtml(outcome.attempt.id)}" />
  <input type="hidden" name="continuation" value="${escapeHtml(outcome.continuation)}" />
  <label>Invite code<input name="invite_code" autocomplete="one-time-code" required autofocus /></label>
  <button type="submit">Continue</button>
</form>`), { "cache-control": "no-store" })
    }
    return html(200, renderPage("Confirm your Inline email", `
<p class="intro">Google cannot confirm continued ownership of this address. Use an existing Inline email to attach this Google account.</p>
<form method="post" action="/v1/auth/provider/send-email-code">
  <input type="hidden" name="attempt_id" value="${escapeHtml(outcome.attempt.id)}" />
  <input type="hidden" name="continuation" value="${escapeHtml(outcome.continuation)}" />
  <label>Existing Inline email<input name="email" type="email" autocomplete="email" required autofocus /></label>
  <button type="submit">Send verification code</button>
</form>`), { "cache-control": "no-store" })
  } catch (cause) {
    if (cause instanceof ProviderCallbackCompletionError) context = cause.context
    Log.shared.error("Provider callback failed", {
      provider,
      cause: cause instanceof ProviderCallbackCompletionError ? cause.cause : cause,
    })
    return providerBrowserError({
      state: context ? undefined : state,
      context,
      code: "failed",
      title: "Sign-in could not finish",
      description: "Return to Inline and try again. No session was shared with this browser.",
    })
  }
}

export async function handleProviderContinueInvite(
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-invite:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.providerContinueInvite,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many invite attempts. Try again shortly.")
  }
  const attemptId = readParam(body, "attempt_id")
  const attemptRate = rateLimiter.consume({
    key: `oauth:abuse:provider-invite:attempt:${normalizeRateLimitKeyPart(attemptId)}`,
    nowMs,
    rule: PROVIDER_INVITE_ATTEMPT_LIMIT,
  })
  if (!attemptRate.allowed) {
    return rateLimitedHtml(attemptRate.retryAfterSeconds, "Too many invite attempts for this sign-in.")
  }
  try {
    const outcome = await continueProviderWithInvite({
      attemptId,
      continuation: readParam(body, "continuation"),
      inviteCode: readParam(body, "invite_code"),
    })
    return finishProviderBrowserLogin(outcome.attempt, outcome.result)
  } catch (cause) {
    const description = cause instanceof InlineError ? cause.description : "The invite code could not be accepted."
    return html(400, renderPage("Invite code error", `<div class="error">${escapeHtml(description ?? "Invalid invite code.")}</div>`))
  }
}

export async function handleProviderSendEmailCode(
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-send-email:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.sendEmailCode,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many email-code requests. Try again shortly.")
  }

  const attemptId = readParam(body, "attempt_id")
  const continuation = readParam(body, "continuation")
  const email = normalizeEmail(readParam(body, "email"))
  try {
    const attempt = await requireProviderEmailAttempt(attemptId, continuation)
    const cooldown = rateLimiter.consume({
      key: `oauth:abuse:provider-email:cooldown:${attempt.id}`,
      nowMs,
      rule: PROVIDER_EMAIL_ATTEMPT_COOLDOWN,
    })
    if (!cooldown.allowed) {
      return rateLimitedHtml(cooldown.retryAfterSeconds, "Wait a moment before requesting another code.")
    }
    const perAttempt = rateLimiter.consume({
      key: `oauth:abuse:provider-email:attempt:${attempt.id}`,
      nowMs,
      rule: PROVIDER_EMAIL_ATTEMPT_LIMIT,
    })
    if (!perAttempt.allowed) {
      return rateLimitedHtml(perAttempt.retryAfterSeconds, "Too many codes were requested for this sign-in.")
    }
    const emailHash = await sha256Hex(email)
    const perEmail = rateLimiter.consume({
      key: `oauth:abuse:provider-email:email:${emailHash}`,
      nowMs,
      rule: config.emailAbuseRateLimits.sendPerEmail,
    })
    if (!perEmail.allowed) {
      return rateLimitedHtml(perEmail.retryAfterSeconds, "Too many attempts for this email. Try again later.")
    }
    const perContext = rateLimiter.consume({
      key: `oauth:abuse:provider-email:context:${emailHash}:${normalizeRateLimitKeyPart(attempt.client.deviceId ?? "unknown")}:${clientIp}`,
      nowMs,
      rule: config.emailAbuseRateLimits.sendPerContext,
    })
    if (!perContext.allowed) {
      return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context. Try again later.")
    }
    const [existing] = await db.select().from(users).where(eq(users.email, email)).limit(1)
    if (!existing || existing.deleted === true) {
      return html(400, renderPage("Email verification failed", `<div class="error">We could not send that verification code.</div>`))
    }
    const sent = await sendEmailCodeHandler({
      email,
      deviceId: attempt.client.deviceId,
      clientType: attempt.client.clientType,
      clientVersion: attempt.client.clientVersion,
      osVersion: attempt.client.osVersion,
      deviceName: attempt.client.deviceName,
    }, { ip: clientIp, source: "/v1/auth/provider/send-email-code" })
    if (!sent.challengeToken) throw new Error("Email challenge is unavailable")
    await ProviderAuthModel.update(attempt.id, { confirmationEmail: email, challengeToken: sent.challengeToken })
    return html(200, renderPage("Check your email", `
<p class="intro">Enter the verification code sent to <strong>${escapeHtml(email)}</strong>.</p>
<form method="post" action="/v1/auth/provider/verify-email-code">
  <input type="hidden" name="attempt_id" value="${escapeHtml(attempt.id)}" />
  <input type="hidden" name="continuation" value="${escapeHtml(continuation)}" />
  <label>Verification code<input name="code" inputmode="numeric" autocomplete="one-time-code" minlength="6" required autofocus /></label>
  <button type="submit">Verify and continue</button>
</form>`), { "cache-control": "no-store" })
  } catch (cause) {
    Log.shared.error("Provider email challenge failed", { cause })
    return html(400, renderPage("Email verification failed", `<div class="error">We could not send that verification code.</div>`))
  }
}

export async function handleProviderVerifyEmailCode(
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const clientIp = resolveClientIp(clientIpOverride)
  const endpointRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-verify-email:${clientIp}`,
    nowMs,
    rule: config.endpointRateLimits.verifyEmailCode,
  })
  if (!endpointRate.allowed) {
    return rateLimitedHtml(endpointRate.retryAfterSeconds, "Too many verification attempts. Try again shortly.")
  }

  const attemptId = readParam(body, "attempt_id")
  const continuation = readParam(body, "continuation")
  let claimed = false
  try {
    const pending = await requireProviderEmailAttempt(attemptId, continuation)
    if (!pending.confirmationEmail || !pending.challengeToken) throw new Error("Email challenge is missing")
    const attemptRate = rateLimiter.consume({
      key: `oauth:abuse:provider-email:verify-attempt:${pending.id}`,
      nowMs,
      rule: PROVIDER_EMAIL_VERIFY_ATTEMPT_LIMIT,
    })
    if (!attemptRate.allowed) {
      return rateLimitedHtml(attemptRate.retryAfterSeconds, "Too many verification attempts for this sign-in.")
    }
    const emailHash = await sha256Hex(pending.confirmationEmail)
    const perEmail = rateLimiter.consume({
      key: `oauth:abuse:provider-email:verify-email:${emailHash}`,
      nowMs,
      rule: config.emailAbuseRateLimits.verifyPerEmail,
    })
    if (!perEmail.allowed) {
      return rateLimitedHtml(perEmail.retryAfterSeconds, "Too many verification attempts for this email.")
    }
    const perContext = rateLimiter.consume({
      key: `oauth:abuse:provider-email:verify-context:${emailHash}:${normalizeRateLimitKeyPart(pending.client.deviceId ?? "unknown")}:${clientIp}`,
      nowMs,
      rule: config.emailAbuseRateLimits.verifyPerContext,
    })
    if (!perContext.allowed) {
      return rateLimitedHtml(perContext.retryAfterSeconds, "Too many attempts from this client context.")
    }

    const attempt = await claimProviderEmailAttempt(attemptId, continuation)
    claimed = true
    if (!attempt.confirmationEmail || !attempt.challengeToken) throw new Error("Email challenge is missing")
    const proof = await verifyEmailAccountProof({
      email: attempt.confirmationEmail,
      code: readParam(body, "code"),
      challengeToken: attempt.challengeToken,
    })
    const completed = await attachProviderAfterEmailProof({ attempt, userId: proof.user.id })
    return finishProviderBrowserLogin(completed.attempt, completed.result)
  } catch (cause) {
    if (claimed && isRetryableProviderEmailProofFailure(cause)) {
      const restored = await restoreProviderEmailAttempt(attemptId, continuation).catch(() => false)
      if (!restored) {
        Log.shared.warn("Failed to restore provider email attempt after invalid code", { attemptId })
      }
    }
    Log.shared.error("Provider email verification failed", { cause })
    return html(401, renderPage("Verification failed", `<div class="error">That verification code is invalid or expired.</div>`))
  }
}

function scheduleProviderCleanup(nowMs: number): void {
  if (providerCleanupInFlight || nowMs < nextProviderCleanupAtMs) return
  nextProviderCleanupAtMs = nowMs + PROVIDER_CLEANUP_INTERVAL_MS
  providerCleanupInFlight = ProviderAuthModel.cleanupExpired(PROVIDER_CLEANUP_BATCH_SIZE)
    .then(() => undefined)
    .catch((cause) => {
      Log.shared.warn("Provider auth cleanup failed", { cause })
    })
    .finally(() => {
      providerCleanupInFlight = undefined
    })
}

function isRetryableProviderEmailProofFailure(cause: unknown): boolean {
  return cause instanceof InlineError &&
    (cause.type === InlineError.ApiError.EMAIL_CODE_EMPTY[0] ||
      cause.type === InlineError.ApiError.EMAIL_CODE_INVALID[0])
}

export async function handleProviderRedeem(
  body: unknown,
  clientIpOverride?: string,
  rateLimiter: InMemoryRateLimiter = legacyRateLimiter,
): Promise<Response> {
  const nowMs = Date.now()
  const redeemRate = rateLimiter.consume({
    key: `oauth:endpoint:provider-redeem:${resolveClientIp(clientIpOverride)}`,
    nowMs,
    rule: config.endpointRateLimits.providerRedeem,
  })
  if (!redeemRate.allowed) {
    return rateLimitedJson(redeemRate.retryAfterSeconds, "Too many ticket redemption attempts. Try again shortly.")
  }
  const ticket = readParam(body, "ticket")
  const codeVerifier = readParam(body, "code_verifier")
  if (!ticket || !codeVerifier) {
    return json(400, { error: "invalid_ticket", error_description: "Ticket and verifier are required." })
  }
  try {
    const result = await redeemProviderTicket(ticket, codeVerifier)
    if (!result) return json(401, { error: "invalid_ticket", error_description: "Ticket is invalid or expired." })
    return json(200, { ok: true, result })
  } catch (cause) {
    if (cause instanceof InlineError && cause.type === InlineError.ApiError.USER_DEACTIVATED[0]) {
      Log.shared.warn("Provider ticket redemption rejected for a deactivated user")
      return json(401, { error: "invalid_ticket", error_description: "Ticket is invalid or expired." })
    }
    throw cause
  }
}

async function finishProviderBrowserLogin(
  attempt: DbProviderAuthAttempt,
  result: ProviderLoginResult,
): Promise<Response> {
  if (attempt.purpose === "hosted_login") {
    if (!attempt.loginTransactionId) throw new Error("Hosted login transaction is missing")
    const completed = await completeHostedLogin({
      transactionId: attempt.loginTransactionId,
      account: { userId: result.userId, method: attempt.provider },
    })
    return completionResponse(completed.targetKind)
  }
  if (attempt.purpose === "app") {
    const ticket = await issueAppTicket(attempt)
    const callback = new URL(`${attempt.appCallbackScheme}://auth/provider`)
    callback.searchParams.set("ticket", ticket)
    if (attempt.appCodeChallenge) callback.searchParams.set("code_challenge", attempt.appCodeChallenge)
    return providerAppHandoffResponse(callback.toString())
  }
  if (!attempt.oauthAuthRequestId) throw new Error("Connected-app authorization request is missing")
  const authRequest = await OauthModel.getAuthRequest(attempt.oauthAuthRequestId, Date.now())
  if (!authRequest) throw new Error("Connected-app authorization request expired")
  return completeAuthorizeSignIn(authRequest, result, attempt.provider)
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
