import { describe, expect, test } from "bun:test"
import { makeAuthorizationKeyCipher } from "./keyCipher"

describe("Inline Protocol authorization-key wrapping", () => {
  test("round trips a key and authenticates its key ID as AAD", () => {
    const cipher = makeAuthorizationKeyCipher({
      activeId: "kek1",
      keys: new Map([["kek1", new Uint8Array(32).fill(0x11)]]),
    })
    const keyId = new Uint8Array(8).fill(0x22)
    const key = Uint8Array.from({ length: 256 }, (_, index) => index)
    const wrapped = cipher.wrap(keyId, key)
    expect(wrapped.length).toBe(284)
    expect(cipher.unwrap(keyId, "kek1", wrapped)).toEqual(Buffer.from(key))
    const wrongId = keyId.slice()
    wrongId[0] = wrongId[0]! ^ 1
    expect(() => cipher.unwrap(wrongId, "kek1", wrapped)).toThrow()
    const tampered = wrapped.slice()
    tampered[50] = tampered[50]! ^ 1
    expect(() => cipher.unwrap(keyId, "kek1", tampered)).toThrow()
  })

  test("reads a predecessor during overlap and writes only with the active KEK", () => {
    const keyId = new Uint8Array(8).fill(0x22)
    const authKey = new Uint8Array(256).fill(0x33)
    const old = makeAuthorizationKeyCipher({
      activeId: "old",
      keys: new Map([["old", new Uint8Array(32).fill(0x44)]]),
    })
    const oldWrapped = old.wrap(keyId, authKey)
    const rotating = makeAuthorizationKeyCipher({
      activeId: "new",
      keys: new Map([
        ["old", new Uint8Array(32).fill(0x44)],
        ["new", new Uint8Array(32).fill(0x55)],
      ]),
    })
    expect(rotating.unwrap(keyId, "old", oldWrapped)).toEqual(Buffer.from(authKey))
    const newWrapped = rotating.wrap(keyId, authKey)
    expect(rotating.activeKeyId).toBe("new")
    expect(rotating.unwrap(keyId, "new", newWrapped)).toEqual(Buffer.from(authKey))
    expect(() => rotating.unwrap(keyId, "old", newWrapped)).toThrow()
  })
})
