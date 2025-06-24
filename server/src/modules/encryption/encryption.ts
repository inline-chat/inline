import { Log } from "@in/server/utils/log"
import { createCipheriv, createDecipheriv, randomBytes } from "crypto"

const ALGORITHM = "aes-256-gcm"
const IV_LENGTH = 12
const AUTH_TAG_LENGTH = 16

const log = new Log("encryption")

// This should be loaded from environment variables
const ENCRYPTION_KEY = process.env["ENCRYPTION_KEY"] as string

if (!ENCRYPTION_KEY) {
  Log.shared.error("Missing MESSAGE_ENCRYPTION_KEY in environment variables")
}

const getEncryptionKey = (): string => {
  const key = process.env["ENCRYPTION_KEY"] as string
  if (!key) {
    throw new Error("Missing MESSAGE_ENCRYPTION_KEY in environment variables")
  }
  return key
}

export interface EmptyEncryptedData {
  encrypted: null
  iv: null
  authTag: null
}

export interface EncryptedData {
  encrypted: Buffer
  iv: Buffer
  authTag: Buffer
}

export type OptionalEncryptedData = EmptyEncryptedData | EncryptedData

/**
 * Low-level binary data encryption function
 * Encrypts raw binary data (Buffer or Uint8Array)
 */
export function encryptBinary(data: Buffer | Uint8Array): EncryptedData {
  // if (data.length === 0) {
  //   return null
  // }

  const ENCRYPTION_KEY = getEncryptionKey()
  validateBinaryData(data)
  const startTime = process.hrtime()
  const key = new Uint8Array(Buffer.from(ENCRYPTION_KEY, "hex"))
  validateKey(key)

  try {
    const iv = new Uint8Array(randomBytes(IV_LENGTH))
    const cipher = createCipheriv(ALGORITHM, key, iv)

    // Convert input to Uint8Array if it's a Buffer
    const inputArray = data instanceof Buffer ? new Uint8Array(data) : data

    // Encrypt the binary data
    const encryptedArray = new Uint8Array(
      Buffer.concat([new Uint8Array(cipher.update(inputArray)), new Uint8Array(cipher.final())]),
    )

    return {
      encrypted: Buffer.from(encryptedArray),
      iv: Buffer.from(iv),
      authTag: Buffer.from(cipher.getAuthTag().buffer),
    }
  } catch (error) {
    if (error instanceof Error) {
      log.error("Binary encryption failed", {
        error: error.message,
        dataLength: data.length,
        duration: process.hrtime(startTime),
      })
    }
    throw error
  } finally {
    key.fill(0)
  }
}

/**
 * Low-level binary data decryption function
 * Decrypts to raw binary data (Buffer)
 */
export function decryptBinary(data: EncryptedData): Buffer {
  const ENCRYPTION_KEY = getEncryptionKey()
  try {
    if (!data.encrypted || !data.iv || !data.authTag) {
      throw new Error("Invalid encrypted data structure")
    }

    // Convert inputs to Uint8Array for internal use
    const key = new Uint8Array(Buffer.from(ENCRYPTION_KEY, "hex"))
    const iv = new Uint8Array(data.iv)
    const encrypted = new Uint8Array(data.encrypted)
    const authTag = new Uint8Array(data.authTag)

    const decipher = createDecipheriv(ALGORITHM, key, iv)
    decipher.setAuthTag(authTag)

    const decryptedArray = new Uint8Array(
      Buffer.concat([new Uint8Array(decipher.update(encrypted)), new Uint8Array(decipher.final())]),
    )

    key.fill(0)
    return Buffer.from(decryptedArray)
  } catch (error) {
    if (error instanceof Error) {
      throw new Error(`Binary decryption failed: ${error.message}`)
    }
    throw error
  }
}

/**
 * High-level text encryption function (uses binary encryption internally)
 * Encrypts text strings
 */
export function encrypt(text: string): EncryptedData {
  validateText(text)
  const textBuffer = Buffer.from(text, "utf8")
  return encryptBinary(textBuffer)
}

/**
 * High-level text decryption function (uses binary decryption internally)
 * Decrypts to text strings
 */
export function decrypt(data: EncryptedData): string {
  const decryptedBuffer = decryptBinary(data)
  return decryptedBuffer.toString("utf8")
}

// Add key validation
const validateKey = (key: Uint8Array): void => {
  if (key.length !== 32) {
    // 256 bits = 32 bytes
    throw new Error("Invalid key length. Expected 32 bytes")
  }
}

const MAX_ENCRYPTED_DATA_LENGTH = 20_000

const validateText = (text: string): void => {
  if (!text) {
    throw new Error("Text to encrypt cannot be empty")
  }
  if (text.length > MAX_ENCRYPTED_DATA_LENGTH) {
    throw new Error("Message exceeds maximum length")
  }
}

const validateBinaryData = (data: Buffer | Uint8Array): void => {
  if (data.length > MAX_ENCRYPTED_DATA_LENGTH) {
    throw new Error("Binary data exceeds maximum length")
  }
}

export const EmptyEncryptedData: EmptyEncryptedData = {
  encrypted: null,
  iv: null,
  authTag: null,
}
