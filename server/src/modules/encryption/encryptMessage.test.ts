import { beforeEach, describe, expect, test } from "bun:test"
import { decryptBinary, encryptBinary } from "./encryption"
import {
  decryptMessage,
  encryptMessage,
  encryptMessageEntities,
} from "./encryptMessage"
import { messageTextLimits } from "@in/server/modules/message/messageTextLimits"

describe("message payload encryption limits", () => {
  beforeEach(() => {
    process.env["ENCRYPTION_KEY"] =
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  })

  test("encrypts and decrypts the full multibyte message-text ceiling", () => {
    const text = "漢".repeat(messageTextLimits.utf16Units)
    const encrypted = encryptMessage(text)
    if (!encrypted.encrypted || !encrypted.iv || !encrypted.authTag) {
      throw new Error("nonempty message was not encrypted")
    }

    expect(decryptMessage(encrypted)).toBe(text)
  })

  test("rejects text beyond the 100,000 UTF-16-unit contract", () => {
    expect(() => encryptMessage("a".repeat(messageTextLimits.utf16Units + 1))).toThrow()
  })

  test("uses a scoped entity ceiling without weakening generic encryption", () => {
    const entities = Buffer.alloc(messageTextLimits.entityBytes, 1)
    expect(decryptBinary(encryptMessageEntities(entities))).toEqual(entities)
    expect(() => encryptMessageEntities(Buffer.alloc(messageTextLimits.entityBytes + 1, 1)))
      .toThrow("Binary data exceeds maximum length")
    expect(() => encryptBinary(Buffer.alloc(20_001, 1)))
      .toThrow("Binary data exceeds maximum length")
  })
})
