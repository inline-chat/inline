import { describe, expect, test } from "bun:test"
import { makeReplayResultCipher, MAX_REPLAY_RESULT_BYTES } from "./replayCipher"

const identity = { authKeyId: new Uint8Array(8).fill(1), protocolSessionId: -2n, messageId: 3n }
const old = new Uint8Array(32).fill(4)
const newer = new Uint8Array(32).fill(5)
const cipher = makeReplayResultCipher({ activeId: "old", keys: new Map([["old", old]]) })

describe("replay storage envelope", () => {
  test("round trips empty, ordinary and maximum-size responses with independent nonces", () => {
    for (const plaintext of [Buffer.alloc(0), Buffer.from("synthetic private response"), Buffer.alloc(MAX_REPLAY_RESULT_BYTES, 6)]) {
      const encrypted = cipher.encrypt(identity, plaintext)
      expect(cipher.decrypt(identity, encrypted)).toEqual(plaintext)
      expect(encrypted.equals(cipher.encrypt(identity, plaintext))).toBeFalse()
      if (plaintext.length > 0) expect(encrypted.includes(plaintext)).toBeFalse()
    }
    expect(() => cipher.encrypt(identity, Buffer.alloc(MAX_REPLAY_RESULT_BYTES + 1))).toThrow()
  })

  test("authenticates every envelope byte and rejects truncation and unknown versions", () => {
    const encrypted = cipher.encrypt(identity, Buffer.from("synthetic response"))
    for (let i = 0; i < encrypted.length; i++) {
      const tampered = Buffer.from(encrypted)
      tampered[i] = tampered[i]! ^ 1
      expect(() => cipher.decrypt(identity, tampered)).toThrow()
    }
    for (let i = 0; i < encrypted.length; i++) expect(() => cipher.decrypt(identity, encrypted.subarray(0, i))).toThrow()
  })

  test("binds ciphertext to the complete row identity", () => {
    const encrypted = cipher.encrypt(identity, Buffer.from("response"))
    for (const wrong of [
      { ...identity, authKeyId: new Uint8Array(8).fill(2) },
      { ...identity, protocolSessionId: 2n },
      { ...identity, messageId: 4n },
    ]) expect(() => cipher.decrypt(wrong, encrypted)).toThrow()
  })

  test("supports retained keys without falling back on missing or incorrect keys", () => {
    const encrypted = cipher.encrypt(identity, Buffer.from("response"))
    const rotated = makeReplayResultCipher({ activeId: "new", keys: new Map([["old", old], ["new", newer]]) })
    expect(rotated.decrypt(identity, encrypted).toString()).toBe("response")
    expect(() => cipher.decrypt(identity, rotated.encrypt(identity, Buffer.from("response")))).toThrow()
    const wrong = makeReplayResultCipher({ activeId: "old", keys: new Map([["old", newer]]) })
    expect(() => wrong.decrypt(identity, encrypted)).toThrow()
  })
})
