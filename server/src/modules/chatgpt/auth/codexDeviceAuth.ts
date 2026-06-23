import { randomUUID } from "node:crypto"
import {
  OPENAI_AUTH_BASE_URL,
  OPENAI_CODEX_CLIENT_ID,
} from "@inline-chat/agent-chatgpt"
import type { ConnectionScope, CodexCredential } from "@in/server/modules/chatgpt/connections/connectionStore"
import { resolveCodexAccessTokenExpiry, resolveCodexAuthIdentity, type CodexIdentity } from "./codexIdentity"

const DEVICE_CODE_TIMEOUT_MS = 15 * 60_000
const DEFAULT_INTERVAL_MS = 5_000
const MIN_INTERVAL_MS = 1_000
const DEVICE_CALLBACK_URL = `${OPENAI_AUTH_BASE_URL}/deviceauth/callback`

type PendingDeviceAuth = {
  readonly id: string
  readonly ownerUserId: number
  readonly scope: ConnectionScope
  readonly deviceAuthId: string
  readonly userCode: string
  readonly verificationUrl: string
  readonly intervalMs: number
  readonly expiresAt: number
}

type DeviceUserCodePayload = {
  device_auth_id?: unknown
  user_code?: unknown
  usercode?: unknown
  interval?: unknown
}

type DeviceTokenPayload = {
  authorization_code?: unknown
  code_verifier?: unknown
}

type OAuthTokenPayload = {
  access_token?: unknown
  refresh_token?: unknown
  expires_in?: unknown
  token_type?: unknown
  scope?: unknown
}

export type CodexDeviceAuthPrompt = {
  readonly pendingId: string
  readonly verificationUrl: string
  readonly userCode: string
  readonly intervalSeconds: number
  readonly expiresAt: number
}

export type CodexDeviceAuthPollResult =
  | { readonly status: "pending" }
  | {
      readonly status: "connected"
      readonly scope: ConnectionScope
      readonly credential: CodexCredential
      readonly identity: CodexIdentity
    }
  | { readonly status: "expired" }
  | { readonly status: "error"; readonly errorCode: string; readonly errorMessage: string }

const pendingAuth = new Map<string, PendingDeviceAuth>()

export async function startCodexDeviceAuth(input: {
  readonly ownerUserId: number
  readonly scope: ConnectionScope
  readonly fetchFn?: typeof fetch
}): Promise<CodexDeviceAuthPrompt> {
  const fetchFn = input.fetchFn ?? fetch
  const requested = await requestDeviceCode(fetchFn)
  const pending: PendingDeviceAuth = {
    id: randomUUID(),
    ownerUserId: input.ownerUserId,
    scope: input.scope,
    deviceAuthId: requested.deviceAuthId,
    userCode: requested.userCode,
    verificationUrl: requested.verificationUrl,
    intervalMs: requested.intervalMs,
    expiresAt: Date.now() + DEVICE_CODE_TIMEOUT_MS,
  }

  pendingAuth.set(pending.id, pending)

  return {
    pendingId: pending.id,
    verificationUrl: pending.verificationUrl,
    userCode: pending.userCode,
    intervalSeconds: Math.ceil(pending.intervalMs / 1000),
    expiresAt: Math.floor(pending.expiresAt / 1000),
  }
}

export async function pollCodexDeviceAuth(input: {
  readonly ownerUserId: number
  readonly pendingId: string
  readonly fetchFn?: typeof fetch
}): Promise<CodexDeviceAuthPollResult> {
  const pending = pendingAuth.get(input.pendingId)
  if (!pending || pending.ownerUserId !== input.ownerUserId) {
    return { status: "error", errorCode: "device_auth_not_found", errorMessage: "Device authorization was not found." }
  }

  if (Date.now() >= pending.expiresAt) {
    pendingAuth.delete(input.pendingId)
    return { status: "expired" }
  }

  const fetchFn = input.fetchFn ?? fetch
  const authorization = await pollDeviceCodeOnce({
    fetchFn,
    deviceAuthId: pending.deviceAuthId,
    userCode: pending.userCode,
  })

  if (authorization.status === "pending") {
    return { status: "pending" }
  }

  if (authorization.status === "error") {
    pendingAuth.delete(input.pendingId)
    return authorization
  }

  const token = await exchangeDeviceCode({
    fetchFn,
    authorizationCode: authorization.authorizationCode,
    codeVerifier: authorization.codeVerifier,
  })
  pendingAuth.delete(input.pendingId)

  return {
    status: "connected",
    scope: pending.scope,
    credential: token,
    identity: resolveCodexAuthIdentity({ accessToken: token.accessToken }),
  }
}

function authHeaders(contentType: string): Record<string, string> {
  return {
    "Content-Type": contentType,
    originator: "inline",
    "User-Agent": "inline",
  }
}

async function requestDeviceCode(fetchFn: typeof fetch): Promise<{
  readonly deviceAuthId: string
  readonly userCode: string
  readonly verificationUrl: string
  readonly intervalMs: number
}> {
  const response = await fetchFn(`${OPENAI_AUTH_BASE_URL}/api/accounts/deviceauth/usercode`, {
    method: "POST",
    headers: authHeaders("application/json"),
    body: JSON.stringify({
      client_id: OPENAI_CODEX_CLIENT_ID,
    }),
  })

  const bodyText = await response.text()
  if (!response.ok) {
    throw new Error(formatDeviceAuthError("OpenAI device code request failed", response.status, bodyText))
  }

  const body = parseJsonObject(bodyText) as DeviceUserCodePayload | null
  const deviceAuthId = trimString(body?.device_auth_id)
  const userCode = trimString(body?.user_code) ?? trimString(body?.usercode)
  if (!deviceAuthId || !userCode) {
    throw new Error("OpenAI device code response was missing the device code or user code.")
  }

  return {
    deviceAuthId,
    userCode,
    verificationUrl: `${OPENAI_AUTH_BASE_URL}/codex/device`,
    intervalMs: normalizeMilliseconds(body?.interval) ?? DEFAULT_INTERVAL_MS,
  }
}

async function pollDeviceCodeOnce(input: {
  readonly fetchFn: typeof fetch
  readonly deviceAuthId: string
  readonly userCode: string
}): Promise<
  | { readonly status: "pending" }
  | { readonly status: "authorized"; readonly authorizationCode: string; readonly codeVerifier: string }
  | { readonly status: "error"; readonly errorCode: string; readonly errorMessage: string }
> {
  const response = await input.fetchFn(`${OPENAI_AUTH_BASE_URL}/api/accounts/deviceauth/token`, {
    method: "POST",
    headers: authHeaders("application/json"),
    body: JSON.stringify({
      device_auth_id: input.deviceAuthId,
      user_code: input.userCode,
    }),
  })

  const bodyText = await response.text()
  if (response.status === 403 || response.status === 404) {
    await delay(MIN_INTERVAL_MS)
    return { status: "pending" }
  }

  if (!response.ok) {
    return {
      status: "error",
      errorCode: `openai_device_auth_${response.status}`,
      errorMessage: formatDeviceAuthError("OpenAI device authorization failed", response.status, bodyText),
    }
  }

  const body = parseJsonObject(bodyText) as DeviceTokenPayload | null
  const authorizationCode = trimString(body?.authorization_code)
  const codeVerifier = trimString(body?.code_verifier)
  if (!authorizationCode || !codeVerifier) {
    return {
      status: "error",
      errorCode: "openai_device_auth_invalid_response",
      errorMessage: "OpenAI device authorization response was missing the exchange code.",
    }
  }

  return { status: "authorized", authorizationCode, codeVerifier }
}

export async function exchangeDeviceCode(input: {
  readonly fetchFn?: typeof fetch
  readonly authorizationCode: string
  readonly codeVerifier: string
}): Promise<CodexCredential> {
  const fetchFn = input.fetchFn ?? fetch
  const response = await fetchFn(`${OPENAI_AUTH_BASE_URL}/oauth/token`, {
    method: "POST",
    headers: authHeaders("application/x-www-form-urlencoded"),
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: input.authorizationCode,
      redirect_uri: DEVICE_CALLBACK_URL,
      client_id: OPENAI_CODEX_CLIENT_ID,
      code_verifier: input.codeVerifier,
    }),
  })

  const bodyText = await response.text()
  if (!response.ok) {
    throw new Error(formatDeviceAuthError("OpenAI device token exchange failed", response.status, bodyText))
  }

  return parseCredential(bodyText)
}

export function parseCredential(bodyText: string): CodexCredential {
  const body = parseJsonObject(bodyText) as OAuthTokenPayload | null
  const accessToken = trimString(body?.access_token)
  const refreshToken = trimString(body?.refresh_token)
  if (!accessToken || !refreshToken) {
    throw new Error("OpenAI token exchange succeeded but did not return OAuth tokens.")
  }

  const expiresInMs = normalizeTokenLifetimeMs(body?.expires_in)
  const expiresAt = expiresInMs !== undefined ? Date.now() + expiresInMs : resolveCodexAccessTokenExpiry(accessToken)
  const scopes = typeof body?.scope === "string" ? body.scope.split(/\s+/).filter(Boolean) : undefined
  const tokenType = trimString(body?.token_type)

  return {
    accessToken,
    refreshToken,
    ...(expiresAt ? { expiresAt } : {}),
    ...(tokenType ? { tokenType } : {}),
    ...(scopes ? { scopes } : {}),
  }
}

function parseJsonObject(text: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(text)
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null
  } catch {
    return null
  }
}

function trimString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined
}

function normalizeMilliseconds(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return Math.trunc(value * 1000)
  }
  if (typeof value === "string" && /^\d+$/.test(value.trim())) {
    return Number.parseInt(value.trim(), 10) * 1000
  }
  return undefined
}

function normalizeTokenLifetimeMs(value: unknown): number | undefined {
  return normalizeMilliseconds(value)
}

function formatDeviceAuthError(prefix: string, status: number, bodyText: string): string {
  const body = parseJsonObject(bodyText)
  const error = trimString(body?.["error"])
  const description = trimString(body?.["error_description"])
  if (error && description) {
    return `${prefix}: ${sanitizeErrorText(error)} (${sanitizeErrorText(description)})`
  }
  if (error) {
    return `${prefix}: ${sanitizeErrorText(error)}`
  }
  const safeBody = sanitizeErrorText(bodyText)
  return safeBody ? `${prefix}: HTTP ${status} ${safeBody}` : `${prefix}: HTTP ${status}`
}

function sanitizeErrorText(value: string): string {
  let text = ""
  for (const char of value) {
    const code = char.charCodeAt(0)
    text += code < 32 || (code >= 127 && code <= 159) ? " " : char
  }
  return text.replace(/\s+/g, " ").trim().slice(0, 500)
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
