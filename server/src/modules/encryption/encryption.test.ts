import { describe, it, expect, beforeEach } from "bun:test"
import { encrypt, decrypt, type EncryptedData } from "./encryption"

describe("encryption", () => {
  beforeEach(() => {
    // Set up test encryption key
    process.env["ENCRYPTION_KEY"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  })

  it("should encrypt and decrypt a message", () => {
    const message = "Hello, World!"
    const encrypted = encrypt(message)
    const decrypted = decrypt(encrypted)

    expect(decrypted).toBe(message)
  })

  it("should produce different ciphertexts for the same message", () => {
    const message = "Hello, World!"
    const encrypted1 = encrypt(message)
    const encrypted2 = encrypt(message)

    expect(encrypted1.encrypted).not.toEqual(encrypted2.encrypted)
    expect(encrypted1.iv).not.toEqual(encrypted2.iv)
  })

  it("should fail to decrypt with wrong auth tag", () => {
    const message = "Hello, World!"
    const encrypted = encrypt(message)
    const tamperedData: EncryptedData = {
      ...encrypted,
      authTag: Buffer.alloc(16), // Wrong auth tag
    }

    expect(() => decrypt(tamperedData)).toThrow()
  })

  it("should fail to decrypt with wrong IV", () => {
    const message = "Hello, World!"
    const encrypted = encrypt(message)
    const tamperedData: EncryptedData = {
      ...encrypted,
      iv: Buffer.alloc(12), // Wrong IV
    }

    expect(() => decrypt(tamperedData)).toThrow()
  })

  it("should fail to decrypt with tampered ciphertext", () => {
    const message = "Hello, World!"
    const encrypted = encrypt(message)
    const tamperedData: EncryptedData = {
      ...encrypted,
      encrypted: Buffer.concat([new Uint8Array(encrypted.encrypted), new Uint8Array([1])]), // Tampered ciphertext
    }

    expect(() => decrypt(tamperedData)).toThrow()
  })

  it("should reject empty messages", () => {
    expect(() => encrypt("")).toThrow("Text to encrypt cannot be empty")
  })

  it("should reject messages exceeding maximum length", () => {
    const longMessage = "a".repeat(20_001)
    expect(() => encrypt(longMessage)).toThrow("Message exceeds maximum length")
  })

  it("should handle special characters", () => {
    const message = "Hello, 世界! 🌍 \n\t"
    const encrypted = encrypt(message)
    const decrypted = decrypt(encrypted)

    expect(decrypted).toBe(message)
  })

  it("should handle maximum length messages", () => {
    const message = "a".repeat(3000)
    const encrypted = encrypt(message)
    const decrypted = decrypt(encrypted)

    expect(decrypted).toBe(message)
  })

  it("should fail with missing encryption key", () => {
    delete process.env["ENCRYPTION_KEY"]

    expect(() => encrypt("test")).toThrow("Missing MESSAGE_ENCRYPTION_KEY")
  })

  it("should fail with invalid encryption key length", () => {
    process.env["ENCRYPTION_KEY"] = "tooShort"

    expect(() => encrypt("test")).toThrow("Invalid key length")
  })
})
