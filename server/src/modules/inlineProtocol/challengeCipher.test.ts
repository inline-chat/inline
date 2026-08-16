import { describe, expect, test } from "bun:test"
import { InlineProtocolChallengeCipher } from "./challengeCipher"

describe("Inline Protocol challenge identifier encryption", () => {
  test("uses domain-separated AEAD and reads a predecessor only during overlap", () => {
    const challengeId = new Uint8Array(32).fill(1)
    const oldKey = new Uint8Array(32).fill(2)
    const old = new InlineProtocolChallengeCipher({ activeId: "old", keys: new Map([["old", oldKey]]) })
    const value = old.encrypt(challengeId, "person@example.com")
    expect(old.decrypt(challengeId, value.keyId, value.encrypted)).toBe("person@example.com")

    const rotating = new InlineProtocolChallengeCipher({
      activeId: "new",
      keys: new Map([["old", oldKey], ["new", new Uint8Array(32).fill(3)]]),
    })
    expect(rotating.decrypt(challengeId, value.keyId, value.encrypted)).toBe("person@example.com")
    const tampered = value.encrypted.slice()
    tampered[tampered.length - 1] = tampered[tampered.length - 1]! ^ 1
    expect(() => rotating.decrypt(challengeId, value.keyId, tampered)).toThrow()
    expect(() => rotating.decrypt(new Uint8Array(32).fill(4), value.keyId, value.encrypted)).toThrow()
  })
})
