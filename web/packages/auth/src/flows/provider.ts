/**
 * Google and Apple sign-in through the API's provider redirect, as far as it
 * can be modeled without a browser.
 *
 * The server's app flow (modules/auth/provider/service.ts,
 * modules/oauth/httpHandlers.ts handleProviderStart, finishProviderBrowserLogin,
 * handleProviderRedeem) works like this:
 *
 * 1. The client makes a verifier, keeps it, and opens
 *    `GET /v1/auth/provider/start?provider&purpose=app&code_challenge&client_type&device_*`.
 *    The server keeps its own OAuth `state` and nonce; they never reach us.
 * 2. After the provider, the server sends the browser back to the client with
 *    `?ticket=…&code_challenge=…` on success, or `?error=cancelled|failed&code_challenge=…`.
 *    The access invite, when required, is asked on the server's own page
 *    before this hand-off.
 * 3. The client checks that `code_challenge` is the one it started with (this
 *    is the state check), then redeems with
 *    `POST /v1/auth/provider/redeem {ticket, code_verifier}`. The ticket is
 *    useless without the verifier, which never leaves this browser.
 *
 * NOT YET SUPPORTED BY THE SERVER for the web app (needs sign-off, see
 * README.md): the start route accepts only `client_type` ios or macos and
 * returns only to a custom URL scheme. The web needs `client_type=web` and a
 * return to an allow-listed https origin. `WEB_RETURN_PARAM` below is the
 * proposed parameter name, not an existing one.
 */

import type { DeviceFacts, SignInError } from "./api"
import { WEB_CLIENT_TYPE } from "./api"
import type { KeyValueStorage } from "./device"

export type ProviderName = "google" | "apple"

/** Provider attempts live 15 minutes on the server (provider/config.ts:86). */
export const PROVIDER_ATTEMPT_TTL_MS = 15 * 60_000

/** TODO(server): proposed; the start route has no web return today. */
export const WEB_RETURN_PARAM = "return_to"

export const PROVIDER_ATTEMPT_STORAGE_KEY = "inline:provider-sign-in"

/** `globalThis.crypto` in the app; tests may pass a seeded stand-in. */
export type CryptoLike = Pick<Crypto, "getRandomValues" | "subtle">

// ---------------------------------------------------------------------------
// Verifier and challenge (appHandoff.ts: challenge = base64url(sha256(verifier)))

const base64Url = (bytes: Uint8Array): string => {
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

export const createCodeVerifier = (crypto: CryptoLike): string =>
  base64Url(crypto.getRandomValues(new Uint8Array(32)))

export const codeChallengeFor = async (
  crypto: CryptoLike,
  verifier: string,
): Promise<string> =>
  base64Url(
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))),
  )

/** The same checks the server applies (appHandoff.ts). */
export const isValidCodeVerifier = (value: string) => /^[A-Za-z0-9._~-]{43,128}$/.test(value)
export const isValidCodeChallenge = (value: string) => /^[A-Za-z0-9_-]{43}$/.test(value)

// ---------------------------------------------------------------------------
// Pending attempt, kept across the full-page redirect

export type PendingProviderAttempt = {
  provider: ProviderName
  codeVerifier: string
  codeChallenge: string
  createdAt: number
}

/**
 * Keeps one pending attempt. The app passes `sessionStorage`: it survives the
 * redirect in the same tab and is gone when the tab closes. The verifier is
 * a secret for the life of the attempt; it is single use and cleared on any
 * return.
 */
export class ProviderAttemptStore {
  constructor(
    private readonly storage: KeyValueStorage,
    private readonly key = PROVIDER_ATTEMPT_STORAGE_KEY,
  ) {}

  save(attempt: PendingProviderAttempt): boolean {
    try {
      this.storage.setItem(this.key, JSON.stringify({ version: 1, ...attempt }))
      return this.storage.getItem(this.key) !== null
    } catch {
      return false
    }
  }

  load(): PendingProviderAttempt | null {
    let raw: string | null
    try {
      raw = this.storage.getItem(this.key)
    } catch {
      return null
    }
    if (raw == null) return null
    try {
      const value = JSON.parse(raw) as Record<string, unknown>
      if (
        value["version"] !== 1 ||
        (value["provider"] !== "google" && value["provider"] !== "apple") ||
        typeof value["codeVerifier"] !== "string" ||
        typeof value["codeChallenge"] !== "string" ||
        typeof value["createdAt"] !== "number" ||
        !isValidCodeVerifier(value["codeVerifier"]) ||
        !isValidCodeChallenge(value["codeChallenge"])
      ) {
        return null
      }
      return {
        provider: value["provider"],
        codeVerifier: value["codeVerifier"],
        codeChallenge: value["codeChallenge"],
        createdAt: value["createdAt"],
      }
    } catch {
      return null
    }
  }

  clear() {
    try {
      this.storage.removeItem(this.key)
    } catch {
      // A stale attempt expires by its timestamp and fails the state check.
    }
  }
}

export const createProviderAttempt = async (
  crypto: CryptoLike,
  provider: ProviderName,
  now: number,
): Promise<PendingProviderAttempt> => {
  const codeVerifier = createCodeVerifier(crypto)
  return {
    provider,
    codeVerifier,
    codeChallenge: await codeChallengeFor(crypto, codeVerifier),
    createdAt: now,
  }
}

// ---------------------------------------------------------------------------
// Start URL

export type ProviderStartUrlInput = {
  /** The `/v1` base, for example `https://api.inline.chat/v1`. */
  apiBaseUrl: string
  provider: ProviderName
  codeChallenge: string
  device: DeviceFacts
  /** Where the server should send the browser back, on an allow-listed origin. */
  returnUrl: string
}

/**
 * The URL to navigate the tab to. Mirrors the query the Mac app sends
 * (InlineKit/Auth/ProviderSignIn.swift startURL) with the web's client type
 * and the proposed web return in place of `callback_scheme`.
 */
export const buildProviderStartUrl = (input: ProviderStartUrlInput): string => {
  const url = new URL(`${input.apiBaseUrl.replace(/\/+$/, "")}/auth/provider/start`)
  const params: Array<[string, string | undefined]> = [
    ["provider", input.provider],
    ["purpose", "app"],
    [WEB_RETURN_PARAM, input.returnUrl],
    ["code_challenge", input.codeChallenge],
    ["client_type", WEB_CLIENT_TYPE],
    ["device_id", input.device.deviceId],
    ["client_version", input.device.clientVersion],
    ["os_version", input.device.osVersion],
    ["device_name", input.device.deviceName],
    ["timezone", input.device.timeZone],
  ]
  for (const [name, value] of params) {
    if (value) url.searchParams.set(name, value)
  }
  return url.toString()
}

// ---------------------------------------------------------------------------
// Return

export type ProviderReturn = {
  ticket: string | null
  codeChallenge: string | null
  error: string | null
}

const RETURN_PARAMS = ["ticket", "code_challenge", "error"] as const

/** Reads the hand-off parameters, or null when the URL carries none. */
export const parseProviderReturn = (url: string): ProviderReturn | null => {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return null
  }
  const read = (name: string) => {
    const value = parsed.searchParams.get(name)
    return value ? value : null
  }
  const result = {
    ticket: read("ticket"),
    codeChallenge: read("code_challenge"),
    error: read("error"),
  }
  if (!result.ticket && !result.codeChallenge && !result.error) return null
  return result
}

/** The same URL without the hand-off parameters, for `history.replaceState`. */
export const stripProviderReturnParams = (url: string): string => {
  const parsed = new URL(url)
  for (const name of RETURN_PARAMS) parsed.searchParams.delete(name)
  return parsed.toString()
}

export type ValidatedProviderReturn =
  | { ok: true; ticket: string; codeVerifier: string; provider: ProviderName }
  | { ok: false; error: SignInError; provider: ProviderName | null }

/**
 * The state check. A return is accepted only when there is a pending attempt
 * from this tab, it is younger than the server's attempt lifetime, and the
 * returned challenge is exactly the one it started with.
 */
export const validateProviderReturn = (
  returned: ProviderReturn,
  pending: PendingProviderAttempt | null,
  now: number,
): ValidatedProviderReturn => {
  const provider = pending?.provider ?? null
  if (
    !pending ||
    returned.codeChallenge == null ||
    returned.codeChallenge !== pending.codeChallenge ||
    now - pending.createdAt > PROVIDER_ATTEMPT_TTL_MS ||
    now < pending.createdAt
  ) {
    return { ok: false, error: { kind: "providerStateMismatch" }, provider }
  }
  if (returned.error != null) {
    return {
      ok: false,
      error: returned.error === "cancelled" ? { kind: "providerCancelled" } : { kind: "providerFailed" },
      provider,
    }
  }
  if (returned.ticket == null) {
    return { ok: false, error: { kind: "providerFailed" }, provider }
  }
  return { ok: true, ticket: returned.ticket, codeVerifier: pending.codeVerifier, provider: pending.provider }
}
