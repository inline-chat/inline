import { describe, expect, it } from "bun:test"
import { ENCRYPTION2_OVERHEAD_BYTES, Encryption2 } from "./encryption2"

describe("Encryption2 caller-owned payload limits", () => {
  it("keeps generic encryption at 20k while explicit callers can round-trip bounded larger payloads", () => {
    const data = Buffer.alloc(24_576, 7)
    expect(() => Encryption2.encrypt(data)).toThrow("Data exceeds maximum allowed length")
    const encrypted = Encryption2.encryptWithLimit(data, data.byteLength)
    expect(encrypted.byteLength).toBe(data.byteLength + ENCRYPTION2_OVERHEAD_BYTES)
    expect(Encryption2.decryptBinary(encrypted)).toEqual(data)
    expect(() => Encryption2.encryptWithLimit(data, data.byteLength - 1)).toThrow("Data exceeds maximum allowed length")
  })
  it("rejects empty plaintext and invalid explicit limits", () => {
    expect(() => Encryption2.encryptWithLimit(Buffer.alloc(0), 1)).toThrow("cannot be empty")
    for (const limit of [0, -1, 0.5, Infinity, NaN, Number.MAX_SAFE_INTEGER + 1]) {
      expect(() => Encryption2.encryptWithLimit(Buffer.alloc(1), limit)).toThrow("positive safe integer")
    }
  })
})
