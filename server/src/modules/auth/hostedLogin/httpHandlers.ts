import { and, eq } from "drizzle-orm"
import { createHash, randomBytes, timingSafeEqual } from "node:crypto"
import { db } from "@in/server/db"
import { loginTransactions } from "@in/server/db/schema"
import { handler as sendEmailCode } from "@in/server/methods/sendEmailCode"
import { handler as sendSmsCode } from "@in/server/methods/sendSmsCode"
import { verifyEmailAccountProof, verifyPhoneAccountProof } from "@in/server/modules/auth/contactProof"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { authRequestCookieHeader } from "@in/server/modules/oauth/authRequestCookie"
import {
  completeHostedLogin,
  getHostedLoginByCapability,
} from "./service"

const COOKIE_NAME = "inline_hl"
const oauth = oauthConfig()
type HostedLoginTargetKind = "inline_protocol_key" | "oauth_authorization" | "native_app"

const parseHostedLoginTargetKind = (value: string): HostedLoginTargetKind | undefined => {
  if (value === "inline_protocol_key" || value === "oauth_authorization" || value === "native_app") return value
  return undefined
}

const escapeHtml = (value: string): string => value.replace(/[&<>"']/g, (character) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
})[character] ?? character)

const page = (title: string, body: string): Response => new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">
<title>${escapeHtml(title)}</title><style>
:root{font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color-scheme:light dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:#f7f7f5;color:#171717}.shell{width:100%;max-width:440px}.brand{display:flex;align-items:center;justify-content:center;gap:9px;margin-bottom:20px;font-size:16px;font-weight:700}.brand svg{width:27px;height:27px}.card{width:100%;padding:32px;border:1px solid #dededb;border-radius:18px;background:#fff;box-shadow:0 12px 40px #1515130f}h1{margin:0 0 10px;font-size:28px;line-height:1.15}.muted{margin:0;color:#666661;font-size:15px;line-height:1.5}.code{margin:22px 0;padding:16px;border-radius:12px;background:#f2f2ef;text-align:center;font:700 26px ui-monospace,monospace;letter-spacing:.18em}.methods{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:24px}.method-button,.primary-button{display:flex;align-items:center;justify-content:center;width:100%;min-height:48px;padding:12px;border:1px solid #d7d7d2;border-radius:11px;background:#fff;color:#171717;font:650 15px inherit;text-decoration:none}.method-button:hover{background:#f2f2ef}.method-button:focus-visible,.primary-button:focus-visible,.back:focus-visible,input:focus-visible{outline:3px solid #7aa7ff;outline-offset:2px}label{display:block;margin:24px 0 8px;font-size:14px;font-weight:650}input{width:100%;padding:13px;border:1px solid #d7d7d2;border-radius:10px;font:inherit}.primary-button{margin-top:16px;border-color:#171717;background:#171717;color:#fff;cursor:pointer}.back{display:inline-block;margin-top:22px;color:#666661;font-size:14px;text-underline-offset:3px}.error{padding:12px;border-radius:10px;background:#fff0f0;color:#9b1c1c}.trust{margin:18px 4px 0;color:#85857f;font-size:11px;line-height:1.5;text-align:center}@media(max-width:420px){body{align-items:start;padding:22px 14px}.card{padding:24px}.methods{grid-template-columns:1fr}}@media(prefers-color-scheme:dark){body{background:#151515;color:#f4f4f1}.card{background:#202020;border-color:#353535;box-shadow:none}.muted,.back{color:#aaa}.code{background:#30302e;color:#f4f4f1}.method-button{background:#202020;border-color:#444;color:#f4f4f1}.method-button:hover{background:#30302e}input{background:#181818;border-color:#444;color:#fff}.primary-button{border-color:#f4f4f1;background:#f4f4f1;color:#171717}.trust{color:#878881}}
</style></head><body><div class="shell"><div class="brand"><svg viewBox="0 0 54 54" fill="none" aria-hidden="true"><rect x="5" y="5" width="44" height="44" rx="16" stroke="currentColor" stroke-width="10"/><rect x="17" y="17" width="10" height="20" rx="4" fill="currentColor"/></svg><span>Inline</span></div><main class="card">${body}</main><div class="trust">Secure sign-in · Verification codes stay between you and Inline.</div></div></body></html>`, {
  status: 200,
  headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
})

const errorPage = (message: string, status = 400): Response => {
  const response = page("Sign-in error", `<h1>Couldn’t continue</h1><p class="error">${escapeHtml(message)}</p>`)
  return new Response(response.body, { status, headers: response.headers })
}

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

const cliVerificationPrompt = (targetKind: HostedLoginTargetKind, verificationCode: string): string =>
  targetKind === "inline_protocol_key"
    ? `<p class="muted">Confirm that this code matches the one shown in your Inline CLI.</p><div class="code">${escapeHtml(verificationCode)}</div>`
    : "<p class=\"muted\">Choose how you want to sign in.</p>"

export const hostedLoginChooser = (
  targetKind: HostedLoginTargetKind,
  verificationCode: string,
): Response => page(
  "Sign in to Inline",
  `<h1>Sign in to Inline</h1>${cliVerificationPrompt(targetKind, verificationCode)}
<nav class="methods" aria-label="Sign-in methods">
<a class="method-button" href="/v1/auth/provider/start?provider=google&amp;purpose=hosted_login">Google</a>
<a class="method-button" href="/v1/auth/provider/start?provider=apple&amp;purpose=hosted_login">Apple</a>
<a class="method-button" href="/v1/auth/login?method=email">Email</a>
<a class="method-button" href="/v1/auth/login?method=phone">Phone</a>
</nav>`,
)

const hostedLoginMethodForm = (csrf: string, method: "email" | "phone"): Response => {
  const isEmail = method === "email"
  const label = isEmail ? "Email address" : "Phone number"
  const inputName = isEmail ? "email" : "phone_number"
  const inputType = isEmail ? "email" : "tel"
  const autocomplete = isEmail ? "email" : "tel"
  const action = isEmail ? "send-email-code" : "send-sms-code"
  return page(
    `Continue with ${isEmail ? "email" : "phone"}`,
    `<h1>Continue with ${isEmail ? "email" : "phone"}</h1><p class="muted">We’ll send you a 6-digit sign-in code.</p>
<form method="post" action="/v1/auth/login/${action}"><input type="hidden" name="csrf" value="${escapeHtml(csrf)}"><label for="contact">${label}</label><input id="contact" name="${inputName}" type="${inputType}" autocomplete="${autocomplete}" required autofocus><button class="primary-button">Send code</button></form>
<a class="back" href="/v1/auth/login">Back to sign-in methods</a>`,
  )
}

const loginPage = (
  csrf: string,
  targetKind: HostedLoginTargetKind,
  verificationCode: string,
  method: string | null,
): Response => method === "email" || method === "phone"
  ? hostedLoginMethodForm(csrf, method)
  : hostedLoginChooser(targetKind, verificationCode)

export async function handleHostedLoginGet(request: Request): Promise<Response> {
  const url = new URL(request.url)
  const capability = url.searchParams.get("capability")
  if (capability) {
    const transaction = await getHostedLoginByCapability(capability)
    if (!transaction) return errorPage("This sign-in request is invalid or expired.")
    const targetKind = parseHostedLoginTargetKind(transaction.targetKind)
    if (!targetKind) return errorPage("This sign-in request is invalid or expired.")
    const csrf = randomBytes(32).toString("base64url")
    await db.update(loginTransactions).set({
      browserCsrfHash: createHash("sha256").update(csrf).digest(),
    }).where(and(
      eq(loginTransactions.id, transaction.id),
      eq(loginTransactions.status, "pending"),
    ))
    const response = loginPage(csrf, targetKind, transaction.verificationCode, url.searchParams.get("method"))
    response.headers.set("referrer-policy", "no-referrer")
    response.headers.append("set-cookie", `${COOKIE_NAME}=${encodeURIComponent(capability)}; Path=/v1/auth; HttpOnly; Secure; SameSite=Lax; Max-Age=600`)
    response.headers.append("set-cookie", `inline_hl_csrf=${encodeURIComponent(csrf)}; Path=/v1/auth; Secure; SameSite=Lax; Max-Age=600`)
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
    transaction.verificationCode,
    url.searchParams.get("method"),
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
  return hostedLoginVerificationForm(
    targetKind,
    transaction.verificationCode,
    bodyValue(body, "csrf"),
    "email",
    email,
  )
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
    transaction.verificationCode,
    bodyValue(body, "csrf"),
    "phone",
    sent.formattedPhoneNumber,
  )
}

export const hostedLoginVerificationForm = (
  targetKind: HostedLoginTargetKind,
  verificationCode: string,
  csrf: string,
  method: "email" | "phone",
  identifier: string,
): Response => {
  const cliCode = targetKind === "inline_protocol_key"
    ? ` CLI code: <strong>${escapeHtml(verificationCode)}</strong>.`
    : ""
  const inviteCode = targetKind === "inline_protocol_key"
    ? "<label for=\"invite-code\">Invite code (if required)</label><input id=\"invite-code\" name=\"invite_code\">"
    : ""
  return page(
    "Verify sign-in",
    `<h1>Enter your code</h1><p class="muted">We sent a 6-digit code to ${escapeHtml(identifier)}.${cliCode}</p><form method="post" action="/v1/auth/login/verify-${method}-code"><input type="hidden" name="csrf" value="${escapeHtml(csrf)}"><label for="sign-in-code">6-digit code</label><input id="sign-in-code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" required autofocus>${inviteCode}<button class="primary-button">Sign in</button></form>`,
  )
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
  const completed = await completeHostedLogin({
    transactionId: transaction.id,
    account: { userId: proof.user.id, method: "email" },
    ip,
  })
  return completionResponse(completed.targetKind)
}

export async function handleHostedLoginVerifySms(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  if (!transaction?.pendingIdentifier) return errorPage("This sign-in request is invalid or expired.")
  const proof = await verifyPhoneAccountProof({
    phoneNumber: transaction.pendingIdentifier,
    code: bodyValue(body, "code"),
    inviteCode: bodyValue(body, "invite_code") || undefined,
  })
  const completed = await completeHostedLogin({
    transactionId: transaction.id,
    account: { userId: proof.user.id, method: "phone" },
    ip,
  })
  return completionResponse(completed.targetKind)
}

export const hostedLoginSuccessPage = (): Response => page("Signed in", "<h1>You’re signed in</h1><p class=\"muted\">You can close this window and return to the Inline CLI.</p>")

export const completionResponse = (
  targetKind: "inline_protocol_key" | "oauth_authorization" | "native_app",
): Response => targetKind === "oauth_authorization"
  ? new Response(null, { status: 303, headers: { location: "/oauth/authorize/continue", "cache-control": "no-store" } })
  : hostedLoginSuccessPage()
