import { and, eq } from "drizzle-orm"
import { createHash, randomBytes, timingSafeEqual } from "node:crypto"
import { db } from "@in/server/db"
import { loginTransactions, type DbLoginTransaction } from "@in/server/db/schema"
import { OauthModel } from "@in/server/db/models/oauth"
import { handler as sendEmailCode } from "@in/server/methods/sendEmailCode"
import { handler as sendSmsCode } from "@in/server/methods/sendSmsCode"
import { verifyEmailAccountProof, verifyPhoneAccountProof } from "@in/server/modules/auth/contactProof"
import { authPageResponse, escapeHtml, type AuthPageContext } from "@in/server/modules/auth/authPage"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { authRequestCookieHeader } from "@in/server/modules/oauth/authRequestCookie"
import { oauthClientTrust } from "@in/server/modules/oauth/clientTrust"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import {
  cancelHostedLogin,
  completeHostedLogin,
  getHostedLoginByCapability,
  issueHostedLoginCsrf,
  markHostedLoginProven,
  networkFingerprint,
  type AuthenticatedAccount,
} from "./service"

const COOKIE_NAME = "inline_hl"
const oauth = oauthConfig()
const MAX_CONFIRM_ATTEMPTS = 5
const confirmLimiter = new InMemoryRateLimiter({ capacity: 10_000 })
type HostedLoginTargetKind = "inline_protocol_key" | "oauth_authorization" | "native_app"
type HostedLoginTransaction = Pick<DbLoginTransaction, "targetKind" | "client" | "oauthAuthRequestId">

const parseHostedLoginTargetKind = (value: string): HostedLoginTargetKind | undefined => {
  if (value === "inline_protocol_key" || value === "oauth_authorization" || value === "native_app") return value
  return undefined
}

const errorPage = (message: string, status = 400): Response =>
  authPageResponse(status, { title: "Couldn’t continue", body: `<div class="error">${escapeHtml(message)}</div>` })

const statusPage = (title: string, message: string, context?: AuthPageContext): Response =>
  authPageResponse(200, {
    title,
    body: `<div class="status"><p class="intro">${escapeHtml(message)}</p></div>`,
    ...(context ? { context } : {}),
  })

const capabilityCookieHeader = (capability: string): string =>
  `${COOKIE_NAME}=${encodeURIComponent(capability)}; Path=/v1/auth; HttpOnly; Secure; SameSite=Lax; Max-Age=600`

const csrfCookieHeader = (csrf: string): string =>
  `inline_hl_csrf=${encodeURIComponent(csrf)}; Path=/v1/auth; Secure; SameSite=Lax; Max-Age=600`

const cookieValue = (request: Request): string | undefined => {
  const cookie = request.headers.get("cookie") ?? ""
  for (const item of cookie.split(";")) {
    const [name, ...rest] = item.trim().split("=")
    if (name === COOKIE_NAME) return decodeURIComponent(rest.join("="))
  }
  return undefined
}

const bodyValue = (body: unknown, key: string): string => {
  if (body instanceof FormData) return String(body.get(key) ?? "")
  if (body && typeof body === "object") return String((body as Record<string, unknown>)[key] ?? "")
  return ""
}

const sameCode = (provided: string, expected: string): boolean => {
  const left = Buffer.from(provided.trim())
  const right = Buffer.from(expected)
  return left.length === right.length && timingSafeEqual(left, right)
}

export const requireHostedLoginTransaction = async (request: Request, body?: unknown) => {
  const capability = cookieValue(request)
  if (!capability) return undefined
  const transaction = await getHostedLoginByCapability(capability)
  if (!transaction) return undefined
  if (body !== undefined) {
    const csrf = bodyValue(body, "csrf")
    if (!transaction.browserCsrfHash || !csrf) return undefined
    const actual = createHash("sha256").update(csrf).digest()
    if (actual.length !== transaction.browserCsrfHash.length ||
      !timingSafeEqual(actual, transaction.browserCsrfHash)) return undefined
  }
  return transaction
}

/** Who is asking, shown on every step. OAuth names are self-declared, so trust comes from the redirect. */
export async function hostedLoginContext(transaction: HostedLoginTransaction): Promise<AuthPageContext | undefined> {
  const kind = parseHostedLoginTargetKind(transaction.targetKind)
  if (kind === "inline_protocol_key") {
    return { kind: "cli", label: "Inline CLI", ...(transaction.client.deviceName ? { detail: transaction.client.deviceName } : {}) }
  }
  if (kind === "oauth_authorization" && transaction.oauthAuthRequestId) {
    const authRequest = await OauthModel.getAuthRequest(transaction.oauthAuthRequestId, Date.now())
    if (!authRequest) return undefined
    const client = await OauthModel.getClient(authRequest.clientId)
    const trust = oauthClientTrust(authRequest.redirectUri)
    const name = client?.clientName?.trim() || "Connected app"
    return trust.verified
      ? { kind: "verified-app", label: name, detail: trust.host }
      : { kind: "unverified-app", label: "Unverified app", detail: trust.host }
  }
  return undefined
}

const chooserIntro = (targetKind: HostedLoginTargetKind, context?: AuthPageContext): string => {
  if (targetKind === "inline_protocol_key") return "Sign in to connect the Inline CLI to your account."
  if (context?.kind === "verified-app") return `Sign in to connect ${context.label} to your Inline account.`
  if (context?.kind === "unverified-app") return "Sign in to review an app’s request to access your Inline account."
  return "Choose how you want to sign in."
}

export const hostedLoginChooser = (
  targetKind: HostedLoginTargetKind,
  context?: AuthPageContext,
): Response => authPageResponse(200, {
  title: "Sign in to Inline",
  ...(context ? { context } : {}),
  body: `<p class="intro">${escapeHtml(chooserIntro(targetKind, context))}</p>
<nav class="methods" aria-label="Sign-in methods">
<a class="button" href="/v1/auth/provider/start?provider=google&amp;purpose=hosted_login">Continue with Google</a>
<a class="button" href="/v1/auth/provider/start?provider=apple&amp;purpose=hosted_login">Continue with Apple</a>
<a class="button" href="/v1/auth/login?method=email">Continue with email</a>
<a class="button" href="/v1/auth/login?method=phone">Continue with phone</a>
</nav>`,
})

const hostedLoginMethodForm = (csrf: string, method: "email" | "phone", context?: AuthPageContext): Response => {
  const isEmail = method === "email"
  const label = isEmail ? "Email address" : "Phone number"
  return authPageResponse(200, {
    title: `Continue with ${isEmail ? "email" : "phone"}`,
    ...(context ? { context } : {}),
    body: `<p class="intro">We’ll send you a 6-digit sign-in code.</p>
<form method="post" action="/v1/auth/login/${isEmail ? "send-email-code" : "send-sms-code"}"><input type="hidden" name="csrf" value="${escapeHtml(csrf)}"><label for="contact">${label}</label><input id="contact" name="${isEmail ? "email" : "phone_number"}" type="${isEmail ? "email" : "tel"}" autocomplete="${isEmail ? "email" : "tel"}" placeholder="${isEmail ? "name@company.com" : "+1 415 555 0100"}" required autofocus><button>Send code</button></form>
<a class="back" href="/v1/auth/login">Other sign-in options</a>`,
  })
}

const loginPage = (
  csrf: string,
  targetKind: HostedLoginTargetKind,
  method: string | null,
  context?: AuthPageContext,
): Response => method === "email" || method === "phone"
  ? hostedLoginMethodForm(csrf, method, context)
  : hostedLoginChooser(targetKind, context)

export async function handleHostedLoginGet(request: Request): Promise<Response> {
  const url = new URL(request.url)
  const capability = url.searchParams.get("capability")
  if (capability) {
    const transaction = await getHostedLoginByCapability(capability)
    if (!transaction) return errorPage("This sign-in request is invalid or expired.")
    // Once an account has proven itself, confirmation belongs to that browser.
    // Proof also rotates the capability; this guards any link opened in between.
    if (transaction.userId !== null) return errorPage("This sign-in request is invalid or expired.")
    const targetKind = parseHostedLoginTargetKind(transaction.targetKind)
    if (!targetKind) return errorPage("This sign-in request is invalid or expired.")
    const csrf = randomBytes(32).toString("base64url")
    await db.update(loginTransactions).set({
      browserCsrfHash: createHash("sha256").update(csrf).digest(),
    }).where(and(
      eq(loginTransactions.id, transaction.id),
      eq(loginTransactions.status, "pending"),
    ))
    const response = loginPage(csrf, targetKind, url.searchParams.get("method"), await hostedLoginContext(transaction))
    response.headers.append("set-cookie", capabilityCookieHeader(capability))
    response.headers.append("set-cookie", csrfCookieHeader(csrf))
    if (transaction.oauthAuthRequestId) {
      response.headers.append("set-cookie", authRequestCookieHeader(oauth, transaction.oauthAuthRequestId))
    }
    return response
  }
  const transaction = await requireHostedLoginTransaction(request)
  const csrfCookie = (request.headers.get("cookie") ?? "").split(";").map((item) => item.trim())
    .find((item) => item.startsWith("inline_hl_csrf="))?.slice("inline_hl_csrf=".length)
  if (!transaction || !csrfCookie) return errorPage("This sign-in request is invalid or expired.")
  const targetKind = parseHostedLoginTargetKind(transaction.targetKind)
  if (!targetKind) return errorPage("This sign-in request is invalid or expired.")
  return loginPage(
    decodeURIComponent(csrfCookie),
    targetKind,
    url.searchParams.get("method"),
    await hostedLoginContext(transaction),
  )
}

export async function handleHostedLoginSendEmail(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  if (!transaction) return errorPage("This sign-in request is invalid or expired.")
  const targetKind = parseHostedLoginTargetKind(transaction.targetKind)
  if (!targetKind) return errorPage("This sign-in request is invalid or expired.")
  const email = bodyValue(body, "email")
  const sent = await sendEmailCode({ email, ...transaction.client }, { ip, source: "/v1/auth/login" })
  await db.update(loginTransactions).set({ pendingIdentifier: email, challengeToken: sent.challengeToken })
    .where(eq(loginTransactions.id, transaction.id))
  return hostedLoginVerificationForm(targetKind, bodyValue(body, "csrf"), "email", email, await hostedLoginContext(transaction))
}

export async function handleHostedLoginSendSms(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  if (!transaction) return errorPage("This sign-in request is invalid or expired.")
  const targetKind = parseHostedLoginTargetKind(transaction.targetKind)
  if (!targetKind) return errorPage("This sign-in request is invalid or expired.")
  const phoneNumber = bodyValue(body, "phone_number")
  const sent = await sendSmsCode({ phoneNumber, ...transaction.client }, { ip, source: "/v1/auth/login" })
  await db.update(loginTransactions).set({ pendingIdentifier: sent.phoneNumber, challengeToken: null })
    .where(eq(loginTransactions.id, transaction.id))
  return hostedLoginVerificationForm(
    targetKind,
    bodyValue(body, "csrf"),
    "phone",
    sent.formattedPhoneNumber,
    await hostedLoginContext(transaction),
  )
}

export const hostedLoginVerificationForm = (
  targetKind: HostedLoginTargetKind,
  csrf: string,
  method: "email" | "phone",
  identifier: string,
  context?: AuthPageContext,
): Response => {
  // Signup may need an invite; keep it out of the way for everyone else.
  const inviteCode = targetKind === "inline_protocol_key"
    ? `<details><summary>Have an invite code?</summary><label for="invite-code">Invite code</label><input id="invite-code" name="invite_code" type="text" autocomplete="off"></details>`
    : ""
  return authPageResponse(200, {
    title: "Enter your code",
    ...(context ? { context } : {}),
    body: `<p class="intro">We sent a 6-digit code to <strong>${escapeHtml(identifier)}</strong>.</p><form method="post" action="/v1/auth/login/verify-${method}-code"><input type="hidden" name="csrf" value="${escapeHtml(csrf)}"><label for="sign-in-code">Sign-in code</label><input id="sign-in-code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" placeholder="000000" required autofocus>${inviteCode}<button>Continue</button></form>
<a class="back" href="/v1/auth/login">Use a different method</a>`,
  })
}

const startedAgo = (createdAt: Date, now = new Date()): string => {
  const minutes = Math.max(0, Math.round((now.getTime() - createdAt.getTime()) / 60_000))
  if (minutes < 1) return "Just now"
  return minutes === 1 ? "1 minute ago" : `${minutes} minutes ago`
}

/**
 * The CLI login is only authorized after the person who signed in types the
 * code their own terminal shows. A phishing link alone is not enough: the
 * attacker's terminal shows the code, not the victim's.
 */
export function hostedLoginConfirmPage(input: {
  transaction: Pick<DbLoginTransaction, "client" | "createdAt">
  csrf: string
  browserIp?: string | undefined
  error?: string
}): Response {
  const requestNetwork = input.transaction.client.requestNetwork
  const browserNetwork = networkFingerprint(input.browserIp)
  const sameNetwork = requestNetwork !== undefined && requestNetwork === browserNetwork
  const network = requestNetwork === undefined || browserNetwork === undefined
    ? `<div><dt>Network</dt><dd>Unknown</dd></div>`
    : sameNetwork
      ? `<div><dt>Network</dt><dd>Same as this browser</dd></div>`
      : `<div><dt>Network</dt><dd>Different from this browser</dd></div>`
  const device = input.transaction.client.deviceName?.trim()
  return authPageResponse(input.error ? 400 : 200, {
    title: "Sign in the Inline CLI?",
    context: { kind: "cli", label: "Inline CLI", ...(device ? { detail: device } : {}) },
    body: `${input.error ? `<div class="error" role="alert">${escapeHtml(input.error)}</div>` : ""}
<div class="notice warning">Only continue if you, or an agent you run, just started <strong>inline login</strong>. If anyone else sent you this link or code, cancel.</div>
<dl class="facts">
<div><dt>Device</dt><dd>${escapeHtml(device || "Unknown device")}</dd></div>
<div><dt>Started</dt><dd>${escapeHtml(startedAgo(input.transaction.createdAt))}</dd></div>
${network}
</dl>
<form method="post" action="/v1/auth/login/confirm"><input type="hidden" name="csrf" value="${escapeHtml(input.csrf)}"><label for="cli-code">Code shown by inline login</label><input id="cli-code" name="code" inputmode="numeric" autocomplete="off" pattern="[0-9]{6}" maxlength="6" placeholder="000000" autofocus><div class="button-row"><button name="decision" value="confirm">Sign in CLI</button><button name="decision" value="cancel" class="secondary" formnovalidate>Cancel</button></div></form>`,
  })
}

/**
 * Called once the person has proven an account. CLI logins stop here for the
 * terminal-code confirmation; app targets complete immediately as before.
 */
export async function continueHostedLoginAfterProof(input: {
  transaction: Pick<DbLoginTransaction, "id" | "targetKind" | "client" | "createdAt">
  account: AuthenticatedAccount
  ip?: string | undefined
}): Promise<Response> {
  if (input.transaction.targetKind === "inline_protocol_key") {
    const capability = await markHostedLoginProven({ transactionId: input.transaction.id, account: input.account })
    if (!capability) {
      return errorPage("This sign-in request is invalid or expired.")
    }
    const csrf = await issueHostedLoginCsrf(input.transaction.id)
    const response = hostedLoginConfirmPage({ transaction: input.transaction, csrf, browserIp: input.ip })
    // Only this browser learns the rotated capability; the original link is dead.
    response.headers.append("set-cookie", capabilityCookieHeader(capability))
    response.headers.append("set-cookie", csrfCookieHeader(csrf))
    return response
  }
  const completed = await completeHostedLogin({ transactionId: input.transaction.id, account: input.account, ip: input.ip })
  return completionResponse(completed.targetKind)
}

export async function handleHostedLoginVerifyEmail(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  if (!transaction?.pendingIdentifier) return errorPage("This sign-in request is invalid or expired.")
  const proof = await verifyEmailAccountProof({
    email: transaction.pendingIdentifier,
    code: bodyValue(body, "code"),
    challengeToken: transaction.challengeToken ?? undefined,
    inviteCode: bodyValue(body, "invite_code") || undefined,
  })
  return continueHostedLoginAfterProof({ transaction, account: { userId: proof.user.id, method: "email" }, ip })
}

export async function handleHostedLoginVerifySms(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  if (!transaction?.pendingIdentifier) return errorPage("This sign-in request is invalid or expired.")
  const proof = await verifyPhoneAccountProof({
    phoneNumber: transaction.pendingIdentifier,
    code: bodyValue(body, "code"),
    inviteCode: bodyValue(body, "invite_code") || undefined,
  })
  return continueHostedLoginAfterProof({ transaction, account: { userId: proof.user.id, method: "phone" }, ip })
}

const provenMethod = (value: string | null): AuthenticatedAccount["method"] | undefined =>
  value === "email" || value === "phone" || value === "google" || value === "apple" ? value : undefined

export async function handleHostedLoginConfirm(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  const method = provenMethod(transaction?.authMethod ?? null)
  if (!transaction || transaction.targetKind !== "inline_protocol_key" || !transaction.userId || !method) {
    return errorPage("This sign-in request is invalid or expired.")
  }
  if (bodyValue(body, "decision") === "cancel") {
    await cancelHostedLogin(transaction.id)
    return statusPage("Sign-in cancelled", "The CLI wasn’t signed in. You can close this window.")
  }
  const attempt = confirmLimiter.consume({
    key: `hosted-login-confirm:${transaction.id}`,
    nowMs: Date.now(),
    rule: { max: MAX_CONFIRM_ATTEMPTS, windowMs: 10 * 60_000 },
  })
  if (!attempt.allowed) {
    await cancelHostedLogin(transaction.id)
    return statusPage("Sign-in cancelled", "Too many incorrect codes. Run inline login again to start over.")
  }
  if (!sameCode(bodyValue(body, "code"), transaction.verificationCode)) {
    return hostedLoginConfirmPage({
      transaction,
      csrf: bodyValue(body, "csrf"),
      browserIp: ip,
      error: "That code doesn’t match. Enter the 6-digit code shown by inline login.",
    })
  }
  const completed = await completeHostedLogin({
    transactionId: transaction.id,
    account: { userId: transaction.userId, method },
    ip,
  })
  return completionResponse(completed.targetKind)
}

export const hostedLoginSuccessPage = (): Response =>
  statusPage("CLI signed in", "You can close this window and return to your terminal.", { kind: "cli", label: "Inline CLI" })

export const completionResponse = (
  targetKind: "inline_protocol_key" | "oauth_authorization" | "native_app",
): Response => targetKind === "oauth_authorization"
  ? new Response(null, { status: 303, headers: { location: "/oauth/authorize/continue", "cache-control": "no-store" } })
  : hostedLoginSuccessPage()
