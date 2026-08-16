import { API_BASE_URL } from "@in/server/env"

export type ProviderAuthConfig = {
  baseUrl: string
  attemptTtlMs: number
  google: { clientId: string; clientSecret: string } | null
  apple: { clientId: string; teamId: string; keyId: string; privateKey: Uint8Array } | null
}

const requiredPair = (first: string | undefined, second: string | undefined) =>
  Boolean(first) === Boolean(second)

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
    baseUrl: process.env["PROVIDER_AUTH_BASE_URL"] || API_BASE_URL,
    attemptTtlMs: 15 * 60_000,
    google: googleClientId && googleClientSecret
      ? { clientId: googleClientId, clientSecret: googleClientSecret }
      : null,
    apple: appleClientId && appleTeamId && appleKeyId && applePrivateKey
      ? {
          clientId: appleClientId,
          teamId: appleTeamId,
          keyId: appleKeyId,
          privateKey: new TextEncoder().encode(applePrivateKey.replaceAll("\\n", "\n")),
        }
      : null,
  }
}
