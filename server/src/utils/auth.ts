import crypto from "crypto"
import { customAlphabet } from "nanoid"
import { alphanumeric } from "nanoid-dictionary"

export const MAX_LOGIN_ATTEMPTS = 5
export const USER_TOKEN_PREFIX = "IN"
export const USER_TOKEN_LENGTH = 32

/**
 * Accepts either a raw token (`"123:IN..."`) or an Authorization header value
 * (`"Bearer 123:IN..."`) and returns the raw token.
 */
export function normalizeToken(token: unknown): string | null {
  if (typeof token !== "string") return null

  const trimmed = token.trim()
  if (!trimmed) return null

  // Case-insensitive "Bearer <token>" (allow extra whitespace).
  if (/^bearer\b/i.test(trimmed)) {
    const withoutPrefix = trimmed.slice("bearer".length).trim()
    return withoutPrefix || null
  }

  return trimmed
}

export function secureRandomSixDigitNumber() {
  return crypto.randomInt(100000, 1000000)
}

const nanoid = customAlphabet(alphanumeric, USER_TOKEN_LENGTH)

export async function generateToken(userId: number) {
  // Generate a random token
  const randomPart = nanoid()
  const token = `${userId}:${USER_TOKEN_PREFIX}${randomPart}`

  // Create a SHA256 hash for storing in the database
  const tokenHash = hashToken(token)

  return { token, tokenHash }
}

export function hashToken(token: string): string {
  const hasher = new Bun.CryptoHasher("sha256")
  hasher.update(token)
  return hasher.digest("base64")
}
