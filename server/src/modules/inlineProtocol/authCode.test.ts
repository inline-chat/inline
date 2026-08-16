import { describe, expect, test } from "bun:test"
import { createHmac } from "node:crypto"
import {
  inlineProtocolAuthCodeMac,
  inlineProtocolKeyedHash,
  randomInlineProtocolAuthCode,
} from "./authCode"

describe("Inline Protocol authentication code protection", () => {
  test("binds the challenge, length-delimited identifier, and code to a secret pepper", () => {
    const pepper = Uint8Array.from({ length: 32 }, (_, index) => index)
    const challenge = Uint8Array.from({ length: 32 }, (_, index) => 255 - index)
    expect(inlineProtocolAuthCodeMac(pepper, challenge, "user@example.com", "004201").toString("hex"))
      .toBe("641995bad7dbd218d5d6db13088c1c949e44259296d239bc289fe93bfb36b082")
    expect(inlineProtocolAuthCodeMac(pepper, challenge, "user@example.com", "004202"))
      .not.toEqual(inlineProtocolAuthCodeMac(pepper, challenge, "user@example.com", "004201"))
  })

  test("domain-separates rate-limit signals and emits fixed-width decimal codes", () => {
    const pepper = new Uint8Array(32)
    expect(inlineProtocolKeyedHash(pepper, "identifier", "same"))
      .not.toEqual(inlineProtocolKeyedHash(pepper, "device", "same"))
    for (let index = 0; index < 100; index += 1) {
      expect(randomInlineProtocolAuthCode()).toMatch(/^\d{6}$/)
    }
    expect(createHmac("sha256", pepper).update("identifier\0same").digest())
      .toHaveLength(inlineProtocolKeyedHash(pepper, "identifier", "same").length)
    expect(createHmac("sha256", pepper).update("identifier\0same").digest("hex"))
      .toBe(inlineProtocolKeyedHash(pepper, "identifier", "same").toString("hex"))
  })
})
