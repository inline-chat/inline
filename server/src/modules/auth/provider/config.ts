import { API_BASE_URL } from "@in/server/env"
import { createPrivateKey } from "node:crypto"

export type ProviderAuthConfig = {
  baseUrl: string
  attemptTtlMs: number
  google: { clientId: string; clientSecret: string } | null
  apple: { clientId: string; teamId: string; keyId: string; privateKey: Uint8Array } | null
}

export type RequiredProviderAuthConfig = Omit<ProviderAuthConfig, "google" | "apple"> & {
  google: NonNullable<ProviderAuthConfig["google"]>
  apple: NonNullable<ProviderAuthConfig["apple"]>
}

const requiredPair = (first: string | undefined, second: string | undefined) =>
  Boolean(first) === Boolean(second)

export function decodeApplePrivateKey(value: string): Uint8Array {
  let key
  try {
    key = createPrivateKey({
      key: value.replaceAll("\\n", "\n"),
      format: "pem",
      type: "pkcs8",
    })
  } catch (cause) {
    throw new Error("APPLE_AUTH_PRIVATE_KEY must be a valid PKCS#8 PEM private key", { cause })
  }

  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
    throw new Error("APPLE_AUTH_PRIVATE_KEY must use the P-256 elliptic curve")
  }
  try {
    return new Uint8Array(key.export({ format: "der", type: "pkcs8" }))
  } catch (cause) {
    throw new Error("APPLE_AUTH_PRIVATE_KEY could not be converted to PKCS#8 DER", { cause })
  }
}

function normalizeProviderBaseUrl(value: string): string {
  const url = new URL(value)
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error("PROVIDER_AUTH_BASE_URL must use HTTP or HTTPS")
  }
  url.pathname = url.pathname.replace(/\/+$/, "")
  url.search = ""
  url.hash = ""
  return url.toString().replace(/\/$/, "")
}

export function providerAuthConfig(): ProviderAuthConfig {
  const googleClientId = process.env["GOOGLE_AUTH_CLIENT_ID"]
  const googleClientSecret = process.env["GOOGLE_AUTH_CLIENT_SECRET"]
  if (!requiredPair(googleClientId, googleClientSecret)) {
    throw new Error("GOOGLE_AUTH_CLIENT_ID and GOOGLE_AUTH_CLIENT_SECRET must be configured together")
  }

  const appleClientId = process.env["APPLE_AUTH_CLIENT_ID"]
  const appleTeamId = process.env["APPLE_AUTH_TEAM_ID"]
  const appleKeyId = process.env["APPLE_AUTH_KEY_ID"]
  const applePrivateKey = process.env["APPLE_AUTH_PRIVATE_KEY"]
  const appleValues = [appleClientId, appleTeamId, appleKeyId, applePrivateKey]
  if (appleValues.some(Boolean) && !appleValues.every(Boolean)) {
    throw new Error("All APPLE_AUTH_* provider credentials must be configured together")
  }

  return {
    baseUrl: normalizeProviderBaseUrl(process.env["PROVIDER_AUTH_BASE_URL"] || API_BASE_URL),
    attemptTtlMs: 15 * 60_000,
    google: googleClientId && googleClientSecret
      ? { clientId: googleClientId, clientSecret: googleClientSecret }
      : null,
    apple: appleClientId && appleTeamId && appleKeyId && applePrivateKey
      ? {
          clientId: appleClientId,
          teamId: appleTeamId,
          keyId: appleKeyId,
          privateKey: decodeApplePrivateKey(applePrivateKey),
        }
      : null,
  }
}

export function requireProviderAuthConfig(
  config: ProviderAuthConfig = providerAuthConfig(),
): RequiredProviderAuthConfig {
  const missing: string[] = []
  if (!config.google) {
    missing.push("Google (GOOGLE_AUTH_CLIENT_ID and GOOGLE_AUTH_CLIENT_SECRET)")
  }
  if (!config.apple) {
    missing.push("Apple (APPLE_AUTH_CLIENT_ID, APPLE_AUTH_TEAM_ID, APPLE_AUTH_KEY_ID, and APPLE_AUTH_PRIVATE_KEY)")
  }
  if (missing.length > 0 || !config.google || !config.apple) {
    throw new Error(`Required provider authentication credentials are missing: ${missing.join("; ")}`)
  }
  return { ...config, google: config.google, apple: config.apple }
}
