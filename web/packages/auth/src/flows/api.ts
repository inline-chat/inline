/**
 * Typed HTTP client for the sign-in routes of the Inline API.
 *
 * Shapes follow the server code (see README.md for file and line). Every call
 * is a JSON POST, so codes, tokens and tickets never go into a URL. Nothing
 * here logs, and no error value carries a code, token, ticket or response
 * body: errors are a closed union built from the server's error identifier and
 * HTTP status only.
 */

import { getApiBaseUrl } from "@inline/config"
import { parseInlineId, type UserID } from "@inline/ids"
import type { Clock, TimerHandle } from "./clock"

/** The session `clientType` the server records for this app (sessions.ts:21). */
export const WEB_CLIENT_TYPE = "web"

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>

/** Facts about this browser that the server stores on the session. */
export type DeviceFacts = {
  deviceId: string
  deviceName: string
  /** Up to four dot-separated numbers; the server drops anything else. */
  clientVersion?: string
  /** Up to four dot-separated numbers; the server drops anything else. */
  osVersion?: string
  /** IANA time zone, for example "Europe/Berlin". Sent on verify only. */
  timeZone?: string
}

export type SignInError =
  | { kind: "network" }
  | { kind: "rateLimited"; retryAfterSeconds: number | null }
  | { kind: "invalidCode" }
  | { kind: "expiredCode" }
  | { kind: "inviteRequired" }
  | { kind: "invalidInvite"; reason: "format" | "notFound" | "taken" }
  | { kind: "invalidEmail" }
  | { kind: "invalidPhone" }
  | { kind: "signupsDisabled" }
  | { kind: "accountDeactivated" }
  | { kind: "invalidTicket" }
  | { kind: "providerCancelled" }
  | { kind: "providerFailed" }
  | { kind: "providerStateMismatch" }
  | { kind: "server"; status: number; code: string | null }

export type SignInErrorKind = SignInError["kind"]

export type ApiResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: SignInError }

export type SignInUser = {
  id: UserID
  firstName: string | null
  lastName: string | null
  username: string | null
  email: string | null
  phoneNumber: string | null
  pendingSetup: boolean
  timeZone: string | null
}

export type LoginSession = {
  userId: UserID
  token: string
  user: SignInUser
}

export type SendEmailCodeResult = {
  existingUser: boolean
  needsInviteCode: boolean
  challengeToken: string | null
}

export type SendSmsCodeResult = {
  existingUser: boolean
  needsInviteCode: boolean
  /** E.164, as the server normalized it. Verify with this value. */
  phoneNumber: string
  /** International format for display. */
  formattedPhoneNumber: string
}

export type SignInApi = {
  sendEmailCode(email: string): Promise<ApiResult<SendEmailCodeResult>>
  verifyEmailCode(input: {
    email: string
    code: string
    challengeToken: string | null
    inviteCode: string | null
  }): Promise<ApiResult<LoginSession>>
  sendSmsCode(phoneNumber: string): Promise<ApiResult<SendSmsCodeResult>>
  verifySmsCode(input: {
    phoneNumber: string
    code: string
    inviteCode: string | null
  }): Promise<ApiResult<LoginSession>>
  checkInviteCode(inviteCode: string): Promise<ApiResult<{ valid: boolean }>>
  redeemProviderTicket(input: {
    ticket: string
    codeVerifier: string
  }): Promise<ApiResult<LoginSession>>
  /** Revokes the session on the server (`POST /v1/logout`). */
  logout(token: string): Promise<ApiResult<void>>
}

export type SignInApiOptions = {
  fetch: FetchLike
  /** The `/v1` base, for example `https://api.inline.chat/v1`. Defaults to `@inline/config`. */
  apiBaseUrl?: string
  /** Read before each request, so a late device name or version is picked up. */
  device: DeviceFacts | (() => DeviceFacts)
  /** With a clock, a request that takes longer than `timeoutMs` fails as `network`. */
  clock?: Clock
  timeoutMs?: number
}

const DEFAULT_TIMEOUT_MS = 20_000

// ---------------------------------------------------------------------------
// Error mapping

const SAFE_ERROR_CODE = /^[A-Za-z_]{1,64}$/

/**
 * Maps a non-success response to the error union. Uses the HTTP status, the
 * `error` identifier and the `retry-after` header. Never the description or
 * any other body text.
 */
export const mapErrorResponse = (
  status: number,
  body: unknown,
  headers: { get(name: string): string | null },
): SignInError => {
  const code =
    body && typeof body === "object" && typeof (body as { error?: unknown }).error === "string"
      ? (body as { error: string }).error
      : null

  // FLOOD is 420 from the OTP budget and the HTTP limiter; the OAuth module
  // and proxies answer 429.
  if (status === 420 || status === 429 || code === "FLOOD" || code === "rate_limited") {
    return { kind: "rateLimited", retryAfterSeconds: parseRetryAfter(headers.get("retry-after")) }
  }

  switch (code) {
    case "EMAIL_CODE_INVALID":
    case "EMAIL_CODE_EMPTY":
    case "SMS_CODE_INVALID":
    case "SMS_CODE_EMPTY":
      return { kind: "invalidCode" }
    case "INVITE_CODE_REQUIRED":
      return { kind: "inviteRequired" }
    case "INVITE_CODE_INVALID":
      return { kind: "invalidInvite", reason: "format" }
    case "INVITE_CODE_NOT_FOUND":
      return { kind: "invalidInvite", reason: "notFound" }
    case "INVITE_CODE_TAKEN":
      return { kind: "invalidInvite", reason: "taken" }
    case "EMAIL_INVALID":
      return { kind: "invalidEmail" }
    case "PHONE_INVALID":
      return { kind: "invalidPhone" }
    case "SIGNUPS_DISABLED":
      return { kind: "signupsDisabled" }
    case "USER_DEACTIVATED":
      return { kind: "accountDeactivated" }
    case "invalid_ticket":
      return { kind: "invalidTicket" }
  }

  return {
    kind: "server",
    status,
    code: code !== null && SAFE_ERROR_CODE.test(code) ? code : null,
  }
}

const parseRetryAfter = (value: string | null): number | null => {
  if (value == null) return null
  const trimmed = value.trim()
  if (!/^\d{1,6}$/.test(trimmed)) return null
  return Number(trimmed)
}

// ---------------------------------------------------------------------------
// Decoding

class MalformedResponse extends Error {}

const record = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new MalformedResponse()
  return value as Record<string, unknown>
}

const bool = (value: unknown): boolean => {
  if (typeof value !== "boolean") throw new MalformedResponse()
  return value
}

const str = (value: unknown): string => {
  if (typeof value !== "string") throw new MalformedResponse()
  return value
}

const optionalStr = (value: unknown): string | null => {
  if (value == null) return null
  return str(value)
}

const positiveUserId = (value: unknown): UserID => {
  const id = parseInlineId<"user">(value, { positive: true })
  if (id == null) throw new MalformedResponse()
  return id
}

const decodeUser = (value: unknown): SignInUser => {
  const user = record(value)
  return {
    id: positiveUserId(user["id"]),
    firstName: optionalStr(user["firstName"]),
    lastName: optionalStr(user["lastName"]),
    username: optionalStr(user["username"]),
    email: optionalStr(user["email"]),
    phoneNumber: optionalStr(user["phoneNumber"]),
    pendingSetup: user["pendingSetup"] === true,
    timeZone: optionalStr(user["timeZone"]),
  }
}

const decodeSession = (value: unknown): LoginSession => {
  const result = record(value)
  const token = str(result["token"])
  if (token.length === 0) throw new MalformedResponse()
  const userId = positiveUserId(result["userId"])
  const user = decodeUser(result["user"])
  if (user.id !== userId) throw new MalformedResponse()
  return { userId, token, user }
}

const decodeSendEmail = (value: unknown): SendEmailCodeResult => {
  const result = record(value)
  return {
    existingUser: bool(result["existingUser"]),
    needsInviteCode: bool(result["needsInviteCode"]),
    challengeToken: optionalStr(result["challengeToken"]),
  }
}

const decodeSendSms = (value: unknown): SendSmsCodeResult => {
  const result = record(value)
  return {
    existingUser: bool(result["existingUser"]),
    needsInviteCode: bool(result["needsInviteCode"]),
    phoneNumber: str(result["phoneNumber"]),
    formattedPhoneNumber: str(result["formattedPhoneNumber"]),
  }
}

const decodeInvite = (value: unknown) => ({ valid: bool(record(value)["valid"]) })

// ---------------------------------------------------------------------------
// Client

const compact = (body: Record<string, string | null | undefined>) => {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(body)) {
    if (value != null && value !== "") out[key] = value
  }
  return out
}

export const createSignInApi = (options: SignInApiOptions): SignInApi => {
  const base = (options.apiBaseUrl ?? getApiBaseUrl()).replace(/\/+$/, "")
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const device = () =>
    typeof options.device === "function" ? options.device() : options.device

  const deviceFields = () => {
    const facts = device()
    return {
      deviceId: facts.deviceId,
      clientType: WEB_CLIENT_TYPE,
      clientVersion: facts.clientVersion,
      osVersion: facts.osVersion,
      deviceName: facts.deviceName,
    }
  }

  const post = async <T>(
    path: string,
    body: Record<string, string>,
    decode: (result: unknown) => T,
    authorization?: string,
  ): Promise<ApiResult<T>> => {
    const controller = typeof AbortController === "undefined" ? null : new AbortController()
    let timer: TimerHandle | undefined
    let timedOut = false
    const timeout = options.clock
      ? new Promise<"timeout">((resolve) => {
          timer = options.clock!.setTimeout(() => {
            timedOut = true
            controller?.abort()
            resolve("timeout")
          }, timeoutMs)
        })
      : null

    const headers: Record<string, string> = {
      accept: "application/json",
      "content-type": "application/json",
    }
    if (authorization) headers["authorization"] = `Bearer ${authorization}`

    let response: Response
    try {
      const request = options.fetch(`${base}${path}`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        credentials: "omit",
        cache: "no-store",
        ...(controller ? { signal: controller.signal } : {}),
      })
      const settled = timeout ? await Promise.race([request, timeout]) : await request
      if (settled === "timeout") return { ok: false, error: { kind: "network" } }
      response = settled
    } catch {
      return { ok: false, error: { kind: "network" } }
    } finally {
      if (timer !== undefined) options.clock!.clearTimeout(timer)
    }
    if (timedOut) return { ok: false, error: { kind: "network" } }

    let parsed: unknown = undefined
    try {
      const text = await response.text()
      parsed = text.length > 0 ? JSON.parse(text) : undefined
    } catch {
      parsed = undefined
    }

    if (response.status < 200 || response.status > 299) {
      return { ok: false, error: mapErrorResponse(response.status, parsed, response.headers) }
    }

    const envelope = parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null
    if (!envelope || envelope["ok"] !== true) {
      // The legacy envelope can carry a failure with a 2xx status.
      if (envelope && envelope["ok"] === false) {
        return { ok: false, error: mapErrorResponse(response.status, envelope, response.headers) }
      }
      return { ok: false, error: { kind: "server", status: response.status, code: null } }
    }
    try {
      return { ok: true, value: decode(envelope["result"]) }
    } catch {
      return { ok: false, error: { kind: "server", status: response.status, code: null } }
    }
  }

  return {
    sendEmailCode: (email) =>
      post("/sendEmailCode", compact({ email, ...deviceFields() }), decodeSendEmail),

    verifyEmailCode: (input) =>
      post(
        "/verifyEmailCode",
        compact({
          email: input.email,
          code: input.code,
          challengeToken: input.challengeToken,
          inviteCode: input.inviteCode,
          ...deviceFields(),
          timezone: device().timeZone,
        }),
        decodeSession,
      ),

    sendSmsCode: (phoneNumber) =>
      post("/sendSmsCode", compact({ phoneNumber, ...deviceFields() }), decodeSendSms),

    verifySmsCode: (input) =>
      post(
        "/verifySmsCode",
        compact({
          phoneNumber: input.phoneNumber,
          code: input.code,
          inviteCode: input.inviteCode,
          ...deviceFields(),
          timezone: device().timeZone,
        }),
        decodeSession,
      ),

    checkInviteCode: (inviteCode) =>
      post("/checkInviteCode", { inviteCode }, decodeInvite),

    redeemProviderTicket: (input) =>
      post(
        "/auth/provider/redeem",
        { ticket: input.ticket, code_verifier: input.codeVerifier },
        decodeSession,
      ),

    logout: (token) => post("/logout", {}, () => undefined, token),
  }
}
