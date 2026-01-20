import { createHmac, randomBytes } from "crypto"

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
const STEP_SECONDS = 30
const CODE_DIGITS = 6

const normalizeBase32 = (value: string) => value.replace(/=+$/g, "").replace(/\s+/g, "").toUpperCase()

export const generateTotpSecret = (bytes: number = 20): string => {
  const buffer = randomBytes(bytes)
  return base32Encode(buffer)
}

export const buildOtpAuthUrl = (issuer: string, accountName: string, secret: string) => {
  const encodedIssuer = encodeURIComponent(issuer)
  const encodedAccount = encodeURIComponent(accountName)
  return `otpauth://totp/${encodedIssuer}:${encodedAccount}?secret=${secret}&issuer=${encodedIssuer}&period=${STEP_SECONDS}&digits=${CODE_DIGITS}`
}

export const generateTotpCode = (secret: string, timestampMs: number = Date.now()): string => {
  const key = base32Decode(secret)
  let counter = Math.floor(timestampMs / 1000 / STEP_SECONDS)
  const counterBuffer = Buffer.alloc(8)

  for (let i = 7; i >= 0; i -= 1) {
    counterBuffer[i] = counter & 0xff
    counter = Math.floor(counter / 256)
  }

  const hmac = createHmac("sha1", key).update(counterBuffer).digest()
  const lastByte = hmac[hmac.length - 1] ?? 0
  const offset = lastByte & 0x0f
  const b0 = hmac[offset] ?? 0
  const b1 = hmac[offset + 1] ?? 0
  const b2 = hmac[offset + 2] ?? 0
  const b3 = hmac[offset + 3] ?? 0
  const binary =
    ((b0 & 0x7f) << 24) |
    ((b1 & 0xff) << 16) |
    ((b2 & 0xff) << 8) |
    (b3 & 0xff)

  const code = (binary % 10 ** CODE_DIGITS).toString().padStart(CODE_DIGITS, "0")
  return code
}

export const verifyTotpCode = (secret: string, code: string, window: number = 1): boolean => {
  const normalizedCode = code.trim()
  if (!/^[0-9]{6}$/.test(normalizedCode)) {
    return false
  }

  const now = Date.now()
  for (let offset = -window; offset <= window; offset += 1) {
    const time = now + offset * STEP_SECONDS * 1000
    if (generateTotpCode(secret, time) === normalizedCode) {
      return true
    }
  }

  return false
}

const base32Encode = (buffer: Buffer): string => {
  let bits = 0
  let value = 0
  let output = ""

  for (const byte of buffer) {
    value = (value << 8) | byte
    bits += 8

    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 31]
      bits -= 5
    }
  }

  if (bits > 0) {
    output += BASE32_ALPHABET[(value << (5 - bits)) & 31]
  }

  return output
}

const base32Decode = (input: string): Buffer => {
  const normalized = normalizeBase32(input)
  let bits = 0
  let value = 0
  const output: number[] = []

  for (const char of normalized) {
    const index = BASE32_ALPHABET.indexOf(char)
    if (index === -1) continue

    value = (value << 5) | index
    bits += 5

    if (bits >= 8) {
      output.push((value >>> (bits - 8)) & 0xff)
      bits -= 8
    }
  }

  return Buffer.from(output)
}
