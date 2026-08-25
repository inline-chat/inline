import { SignJWT, decodeJwt } from "jose"
import { toArrayBufferBackedBytes } from "@in/server/utils/arrayBuffer"
import type { ProviderAuthConfig } from "./config"
import { verifyAppleIdToken, type ProviderClaims } from "./claims"

const appleTokenEndpoint = "https://appleid.apple.com/auth/token"

export type NativeAppleConfig = NonNullable<ProviderAuthConfig["apple"]>

type AppleTokenResponse = {
  id_token?: unknown
}

type AppleFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

export function nativeAppleClientIdFromIdentityToken(
  idToken: string,
  allowedClientIds: readonly string[],
): string {
  const audience = decodeJwt(idToken).aud
  if (typeof audience !== "string" || !allowedClientIds.includes(audience)) {
    throw new Error("Apple identity token has an unsupported native audience")
  }
  return audience
}

export async function createAppleClientSecret(
  config: Pick<NativeAppleConfig, "teamId" | "keyId" | "privateKey">,
  clientId: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    toArrayBufferBackedBytes(config.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  )
  const now = Math.floor(Date.now() / 1_000)
  return new SignJWT({})
    .setProtectedHeader({ typ: "JWT", alg: "ES256", kid: config.keyId })
    .setIssuer(config.teamId)
    .setAudience("https://appleid.apple.com")
    .setSubject(clientId)
    .setIssuedAt(now)
    .setExpirationTime(now + 5 * 60)
    .sign(key)
}

export async function exchangeNativeAppleAuthorizationCode(input: {
  code: string
  clientId: string
  config: NativeAppleConfig
  fetcher?: AppleFetch
}): Promise<string> {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code: input.code,
    client_id: input.clientId,
    client_secret: await createAppleClientSecret(input.config, input.clientId),
  })
  const response = await (input.fetcher ?? fetch)(appleTokenEndpoint, {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
    },
    body,
  })
  if (!response.ok) {
    throw new Error(`Apple native authorization-code exchange failed with status ${response.status}`)
  }
  const payload = await response.json() as AppleTokenResponse
  if (typeof payload.id_token !== "string" || payload.id_token.length === 0) {
    throw new Error("Apple native authorization-code exchange omitted the identity token")
  }
  return payload.id_token
}

type VerifyAppleIdToken = (input: Parameters<typeof verifyAppleIdToken>[0]) => Promise<ProviderClaims>

export async function verifyNativeAppleAuthorization(input: {
  code: string
  identityToken: string
  nonce: string
  firstName?: string
  lastName?: string
  config: NativeAppleConfig
  fetcher?: AppleFetch
  verifyIdToken?: VerifyAppleIdToken
}): Promise<ProviderClaims> {
  const verifyIdToken = input.verifyIdToken ?? verifyAppleIdToken
  const clientId = nativeAppleClientIdFromIdentityToken(input.identityToken, input.config.nativeClientIds)
  const authorizationClaims = await verifyIdToken({
    idToken: input.identityToken,
    clientId,
    nonce: input.nonce,
    firstName: input.firstName,
    lastName: input.lastName,
  })
  const exchangedIdToken = await exchangeNativeAppleAuthorizationCode({
    code: input.code,
    clientId,
    config: input.config,
    fetcher: input.fetcher,
  })
  const exchangedClaims = await verifyIdToken({
    idToken: exchangedIdToken,
    clientId,
    nonce: input.nonce,
  })
  if (
    authorizationClaims.provider !== "apple" ||
    exchangedClaims.provider !== "apple" ||
    exchangedClaims.subject !== authorizationClaims.subject ||
    (exchangedClaims.email && authorizationClaims.email && exchangedClaims.email !== authorizationClaims.email)
  ) {
    throw new Error("Apple authorization code and identity token do not identify the same user")
  }
  return authorizationClaims
}
