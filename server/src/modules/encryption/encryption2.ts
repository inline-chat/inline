import { Log } from "@in/server/utils/log"
import { createCipheriv, createDecipheriv, randomBytes } from "crypto"

// -----------------------------------------------------------------------------
// Encryption-2: single-column binary encryption utilities
// -----------------------------------------------------------------------------
// This module provides helper functions for encrypting and decrypting arbitrary
// binary payloads.  Unlike the first version (encryption.ts) which returns the
// IV, authTag, and ciphertext as separate properties, this implementation
// concatenates them into a single Buffer so the value can be stored in a single
// database column (e.g. Postgres `bytea`).
//
//  Buffer layout: [ IV (12 bytes) | AuthTag (16 bytes) | Ciphertext (n bytes) ]
// -----------------------------------------------------------------------------

const log = new Log("encryption2")

const ALGORITHM = "aes-256-gcm"
const IV_LENGTH = 12 // 96-bit IV for GCM (recommended length)
const AUTH_TAG_LENGTH = 16 // 128-bit authentication tag
const MAX_ENCRYPTED_DATA_LENGTH = 20_000 // Keep parity with v1 implementation

// -----------------------------------------------------------------------------
// Utilities
// -----------------------------------------------------------------------------

/**
 * Lazily fetch and validate the AES-256 key from env variables.
 * Throws if the key is missing or has an unexpected size.
 */
const getEncryptionKey = (): Buffer => {
  const hexKey = process.env["ENCRYPTION_KEY"] as string | undefined
  if (!hexKey) {
    log.error("Missing ENCRYPTION_KEY in environment variables")
    throw new Error("Missing ENCRYPTION_KEY in environment variables")
  }
  const keyBuffer = Buffer.from(hexKey, "hex")
  if (keyBuffer.length !== 32) {
    // 256-bit key ⇒ 32 bytes
    throw new Error("Invalid ENCRYPTION_KEY length. Expected 32 bytes (64 hex chars)")
  }
  return keyBuffer
}

const validatePlaintext = (buf: Buffer | Uint8Array): void => {
  if (buf.byteLength === 0) {
    throw new Error("Data to encrypt cannot be empty")
  }
  if (buf.byteLength > MAX_ENCRYPTED_DATA_LENGTH) {
    throw new Error("Data exceeds maximum allowed length")
  }
}

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------

/**
 * Encrypt binary data (Buffer or Uint8Array) and return a single Buffer that
 * contains IV, authTag, and ciphertext concatenated together.
 */
export function encrypt(data: Buffer | Uint8Array): Buffer {
  validatePlaintext(data)

  const key = getEncryptionKey()
  const iv = randomBytes(IV_LENGTH)
  const cipher = createCipheriv(ALGORITHM, key, iv)

  const plaintext = data instanceof Buffer ? data : Buffer.from(data)
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()])
  const authTag = cipher.getAuthTag()

  // Combined payload
  return Buffer.concat([iv, authTag, encrypted])
}

/**
 * Decrypt combined payload back into raw binary data (Buffer).
 */
export function decryptBinary(combined: Buffer): Buffer {
  if (!combined || combined.length < IV_LENGTH + AUTH_TAG_LENGTH) {
    throw new Error("Invalid encrypted data – too short")
  }

  const iv = combined.subarray(0, IV_LENGTH)
  const authTag = combined.subarray(IV_LENGTH, IV_LENGTH + AUTH_TAG_LENGTH)
  const ciphertext = combined.subarray(IV_LENGTH + AUTH_TAG_LENGTH)

  const key = getEncryptionKey()
  const decipher = createDecipheriv(ALGORITHM, key, iv)
  decipher.setAuthTag(authTag)

  const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()])
  return decrypted
}

/**
 * Convenience helper to decrypt combined payload and return a UTF-8 string.
 */
export function decryptToString(combined: Buffer): string {
  const bin = decryptBinary(combined)
  return bin.toString("utf8")
}

// Aliases kept for compatibility / clarity
export const encryptBinary = encrypt

export const Encryption2 = {
  encrypt,
  decryptBinary,
  decryptToString,
}
