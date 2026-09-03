import { createRemoteJWKSet, jwtVerify, type JWTPayload, type JWTVerifyGetKey } from "jose"
import type { AccountProvider } from "@in/server/db/schema"

const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"))
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"))

export type ProviderClaims = {
  provider: AccountProvider
  subject: string
  email?: string
  authoritativeEmail: boolean
  firstName?: string
  lastName?: string
}

type GooglePayload = JWTPayload & {
  email?: unknown
  email_verified?: unknown
  hd?: unknown
  given_name?: unknown
  family_name?: unknown
  nonce?: unknown
}

type ApplePayload = JWTPayload & {
  email?: unknown
  email_verified?: unknown
  is_private_email?: unknown
  nonce?: unknown
}

export async function verifyGoogleIdToken(input: {
  idToken: string
  clientId: string
  nonce: string
}): Promise<ProviderClaims> {
  const { payload } = await jwtVerify<GooglePayload>(input.idToken, googleKeys, {
    audience: input.clientId,
    issuer: ["https://accounts.google.com", "accounts.google.com"],
    algorithms: ["RS256"],
  })
  assertSubjectAndNonce(payload, input.nonce)

  const email = stringClaim(payload["email"])?.trim().toLowerCase()
  const verified = payload["email_verified"] === true
  const authoritativeEmail = isGoogleAuthoritativeEmail(
    email,
    verified,
    stringClaim(payload["hd"]),
  )

  return {
    provider: "google",
    subject: payload.sub,
    email,
    authoritativeEmail,
    firstName: cleanName(payload["given_name"]),
    lastName: cleanName(payload["family_name"]),
  }
}

export function isGoogleAuthoritativeEmail(
  email: string | undefined,
  verified: boolean,
  hostedDomain: string | undefined,
): boolean {
  return Boolean(email && verified && (email.endsWith("@gmail.com") || hostedDomain))
}

export async function verifyAppleIdToken(input: {
  idToken: string
  clientId: string
  nonce: string
  firstName?: string
  lastName?: string
  keyResolver?: JWTVerifyGetKey
}): Promise<ProviderClaims> {
  const { payload } = await jwtVerify<ApplePayload>(input.idToken, input.keyResolver ?? appleKeys, {
    audience: input.clientId,
    issuer: "https://appleid.apple.com",
    algorithms: ["RS256"],
  })
  assertSubjectAndNonce(payload, input.nonce)

  const email = stringClaim(payload["email"])?.trim().toLowerCase()
  return {
    provider: "apple",
    subject: payload.sub,
    email,
    authoritativeEmail: Boolean(email && (payload["email_verified"] === true || payload["email_verified"] === "true")),
    firstName: cleanName(input.firstName),
    lastName: cleanName(input.lastName),
  }
}

function assertSubjectAndNonce(payload: JWTPayload & { nonce?: unknown }, nonce: string): asserts payload is JWTPayload & { sub: string } {
  if (!payload.sub || payload.nonce !== nonce) {
    throw new Error("Provider identity token has an invalid subject or nonce")
  }
}

function stringClaim(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined
}

function cleanName(value: unknown): string | undefined {
  const name = stringClaim(value)?.trim()
  return name ? name.slice(0, 256) : undefined
}
