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

const escapeHtml = (value: string): string => value.replace(/[&<>"']/g, (character) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
})[character] ?? character)

const page = (title: string, body: string): Response => new Response(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)}</title><style>
:root{font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color-scheme:light dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:#f7f7f5;color:#171717}.card{width:100%;max-width:440px;padding:30px;border:1px solid #dededb;border-radius:18px;background:#fff;box-shadow:0 12px 40px #1515130f}h1{margin:0 0 8px;font-size:25px}.muted{color:#666661;font-size:14px;line-height:1.5}.code{margin:20px 0;padding:14px;border-radius:12px;background:#f2f2ef;text-align:center;font:700 24px ui-monospace,monospace;letter-spacing:.18em}label{display:block;margin:16px 0 6px;font-size:13px;font-weight:650}input{width:100%;padding:12px;border:1px solid #d7d7d2;border-radius:10px;font:inherit}button{width:100%;margin-top:16px;padding:12px;border:0;border-radius:10px;background:#171717;color:#fff;font:650 14px inherit}.tabs{display:flex;gap:8px;margin-top:20px}.tabs button{margin:0;background:#ecece8;color:#171717}.error{padding:12px;border-radius:10px;background:#fff0f0;color:#9b1c1c}@media(prefers-color-scheme:dark){body{background:#151515;color:#f4f4f1}.card{background:#202020;border-color:#353535}.muted{color:#aaa}.code,.tabs button{background:#30302e;color:#f4f4f1}input{background:#181818;border-color:#444;color:#fff}button{background:#f4f4f1;color:#171717}}
</style></head><body><main class="card">${body}</main></body></html>`, {
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

const loginForm = (csrf: string, verificationCode: string): Response => page(
  "Sign in to Inline",
  `<h1>Sign in to Inline</h1><p class="muted">Confirm that this code matches the one shown in your CLI.</p>
<div class="code">${escapeHtml(verificationCode)}</div>
<div class="tabs"><a href="/v1/auth/provider/start?provider=google&amp;purpose=hosted_login"><button type="button">Google</button></a><a href="/v1/auth/provider/start?provider=apple&amp;purpose=hosted_login"><button type="button">Apple</button></a></div>
<form method="post" action="/v1/auth/login/send-email-code"><input type="hidden" name="csrf" value="${escapeHtml(csrf)}"><label>Email address</label><input name="email" type="email" autocomplete="email" required autofocus><button>Continue with email</button></form>
<form method="post" action="/v1/auth/login/send-sms-code"><input type="hidden" name="csrf" value="${escapeHtml(csrf)}"><label>Phone number</label><input name="phone_number" type="tel" autocomplete="tel" required><button>Continue with phone</button></form>`,
)

export async function handleHostedLoginGet(request: Request): Promise<Response> {
  const url = new URL(request.url)
  const capability = url.searchParams.get("capability")
  if (capability) {
    const transaction = await getHostedLoginByCapability(capability)
    if (!transaction) return errorPage("This sign-in request is invalid or expired.")
    const csrf = randomBytes(32).toString("base64url")
    await db.update(loginTransactions).set({
      browserCsrfHash: createHash("sha256").update(csrf).digest(),
    }).where(and(
      eq(loginTransactions.id, transaction.id),
      eq(loginTransactions.status, "pending"),
    ))
    const response = loginForm(csrf, transaction.verificationCode)
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
  return loginForm(decodeURIComponent(csrfCookie), transaction.verificationCode)
}

export async function handleHostedLoginSendEmail(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  if (!transaction) return errorPage("This sign-in request is invalid or expired.")
  const email = bodyValue(body, "email")
  const sent = await sendEmailCode({ email, ...transaction.client }, { ip, source: "/v1/auth/login" })
  await db.update(loginTransactions).set({ pendingIdentifier: email, challengeToken: sent.challengeToken })
    .where(eq(loginTransactions.id, transaction.id))
  return verificationForm(transaction.verificationCode, bodyValue(body, "csrf"), "email", email)
}

export async function handleHostedLoginSendSms(request: Request, body: unknown, ip?: string): Promise<Response> {
  const transaction = await requireHostedLoginTransaction(request, body)
  if (!transaction) return errorPage("This sign-in request is invalid or expired.")
  const phoneNumber = bodyValue(body, "phone_number")
  const sent = await sendSmsCode({ phoneNumber, ...transaction.client }, { ip, source: "/v1/auth/login" })
  await db.update(loginTransactions).set({ pendingIdentifier: sent.phoneNumber, challengeToken: null })
    .where(eq(loginTransactions.id, transaction.id))
  return verificationForm(transaction.verificationCode, bodyValue(body, "csrf"), "phone", sent.formattedPhoneNumber)
}

const verificationForm = (
  verificationCode: string,
  csrf: string,
  method: "email" | "phone",
  identifier: string,
): Response => page("Verify sign-in", `<h1>Enter your code</h1><p class="muted">We sent a code to ${escapeHtml(identifier)}. CLI code: <strong>${escapeHtml(verificationCode)}</strong>.</p><form method="post" action="/v1/auth/login/verify-${method}-code"><input type="hidden" name="csrf" value="${escapeHtml(csrf)}"><label>6-digit code</label><input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" required autofocus><label>Invite code (if required)</label><input name="invite_code"><button>Sign in</button></form>`)

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
