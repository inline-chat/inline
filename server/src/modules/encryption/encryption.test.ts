import { describe, it, expect, beforeEach } from "bun:test"
import { encrypt, decrypt, encryptBinary, decryptBinary, type EncryptedData } from "./encryption"

describe("encryption2", () => {
  beforeEach(() => {
    // Set up test encryption key
    process.env["ENCRYPTION_KEY"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  })

  describe("text encryption (compatibility)", () => {
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

  describe("binary encryption", () => {
    it("should encrypt and decrypt binary data using Buffer", () => {
      const data = Buffer.from([1, 2, 3, 4, 5, 255, 0, 128])
      const encrypted = encryptBinary(data)
      const decrypted = decryptBinary(encrypted)

      expect(decrypted).toEqual(data)
    })

    it("should encrypt and decrypt binary data using Uint8Array", () => {
      const data = new Uint8Array([1, 2, 3, 4, 5, 255, 0, 128])
      const encrypted = encryptBinary(data)
      const decrypted = decryptBinary(encrypted)

      expect(decrypted).toEqual(Buffer.from(data))
    })

    it("should produce different ciphertexts for the same binary data", () => {
      const data = Buffer.from([1, 2, 3, 4, 5])
      const encrypted1 = encryptBinary(data)
      const encrypted2 = encryptBinary(data)

      expect(encrypted1.encrypted).not.toEqual(encrypted2.encrypted)
      expect(encrypted1.iv).not.toEqual(encrypted2.iv)
    })

    it("should handle large binary data", () => {
      const data = Buffer.alloc(10000, 42) // 10KB of data with value 42
      const encrypted = encryptBinary(data)
      const decrypted = decryptBinary(encrypted)

      expect(decrypted).toEqual(data)
    })

    it("should handle empty binary data gracefully", () => {
      const data = Buffer.alloc(0)
      const encrypted = encryptBinary(data)
      const decrypted = decryptBinary(encrypted)

      expect(decrypted).toEqual(Buffer.alloc(0))
    })

    it("should reject binary data exceeding maximum length", () => {
      const data = Buffer.alloc(20_001, 1)
      expect(() => encryptBinary(data)).toThrow("Binary data exceeds maximum length")
    })

    it("should fail to decrypt with wrong auth tag", () => {
      const data = Buffer.from([1, 2, 3, 4, 5])
      const encrypted = encryptBinary(data)
      const tamperedData: EncryptedData = {
        ...encrypted,
        authTag: Buffer.alloc(16), // Wrong auth tag
      }

      expect(() => decryptBinary(tamperedData)).toThrow()
    })

    it("should fail to decrypt with wrong IV", () => {
      const data = Buffer.from([1, 2, 3, 4, 5])
      const encrypted = encryptBinary(data)
      const tamperedData: EncryptedData = {
        ...encrypted,
        iv: Buffer.alloc(12), // Wrong IV
      }

      expect(() => decryptBinary(tamperedData)).toThrow()
    })

    it("should fail to decrypt with tampered ciphertext", () => {
      const data = Buffer.from([1, 2, 3, 4, 5])
      const encrypted = encryptBinary(data)
      const tamperedData: EncryptedData = {
        ...encrypted,
        encrypted: Buffer.concat([new Uint8Array(encrypted.encrypted), new Uint8Array([1])]), // Tampered ciphertext
      }

      expect(() => decryptBinary(tamperedData)).toThrow()
    })

    it("should fail with missing encryption key", () => {
      delete process.env["ENCRYPTION_KEY"]
      const data = Buffer.from([1, 2, 3])

      expect(() => encryptBinary(data)).toThrow("Missing MESSAGE_ENCRYPTION_KEY")
    })

    it("should fail with invalid encryption key length", () => {
      process.env["ENCRYPTION_KEY"] = "tooShort"
      const data = Buffer.from([1, 2, 3])

      expect(() => encryptBinary(data)).toThrow("Invalid key length")
    })
  })

  describe("integration tests", () => {
    it("should produce equivalent results when encrypting text via text vs binary functions", () => {
      const message = "Hello, World!"

      // Encrypt using text function
      const textEncrypted = encrypt(message)
      const textDecrypted = decrypt(textEncrypted)

      // Encrypt using binary function
      const binaryEncrypted = encryptBinary(Buffer.from(message, "utf8"))
      const binaryDecrypted = decryptBinary(binaryEncrypted).toString("utf8")

      expect(textDecrypted).toBe(message)
      expect(binaryDecrypted).toBe(message)
      expect(textDecrypted).toBe(binaryDecrypted)
    })

    it("should handle mixed binary and text data correctly", () => {
      // Create binary data that includes text
      const textPart = "Hello, 世界!"
      const binaryPart = new Uint8Array([0, 255, 128, 64])
      const combinedData = Buffer.concat([Buffer.from(textPart, "utf8"), Buffer.from(binaryPart)])

      const encrypted = encryptBinary(combinedData)
      const decrypted = decryptBinary(encrypted)

      expect(decrypted).toEqual(combinedData)

      // Verify the text part can be extracted
      const extractedText = decrypted.subarray(0, Buffer.from(textPart, "utf8").length).toString("utf8")
      expect(extractedText).toBe(textPart)
    })

    it("should handle various binary data patterns", () => {
      const testPatterns = [
        Buffer.from([0]), // Single zero byte
        Buffer.from([255]), // Single max byte
        Buffer.from([0, 255, 0, 255]), // Alternating pattern
        Buffer.from(Array.from({ length: 100 }, (_, i) => i % 256)), // Sequential pattern
        Buffer.from(Array.from({ length: 1000 }, () => Math.floor(Math.random() * 256))), // Random pattern
      ]

      testPatterns.forEach((pattern, index) => {
        const encrypted = encryptBinary(pattern)
        const decrypted = decryptBinary(encrypted)
        expect(decrypted).toEqual(pattern)
      })
    })
  })
})
