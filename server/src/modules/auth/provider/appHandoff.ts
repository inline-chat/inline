import { createHash } from "node:crypto"

export function createAppCodeChallenge(verifier: string): string {
  return createHash("sha256").update(verifier).digest("base64url")
}

export function isValidAppCodeChallenge(value: string | null): value is string {
  return value !== null && /^[A-Za-z0-9_-]{43}$/.test(value)
}

export function isValidAppCodeVerifier(value: string): boolean {
  return /^[A-Za-z0-9._~-]{43,128}$/.test(value)
}
