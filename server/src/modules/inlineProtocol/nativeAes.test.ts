import { describe, expect, test } from "bun:test"
import { randomBytes } from "node:crypto"
import { getAesBackend, setAesBackend } from "@inline-chat/protocol/secure"
import { nodeAesBackend } from "@inline-chat/protocol/secure/node"
import { installServerAesBackend, loadNativeIgeDecrypt } from "./nativeAes"

describe("native AES-IGE decryption", () => {
  test("falls back to the JS backend when no library loads", () => {
    const status = installServerAesBackend(["/nonexistent/libcrypto.so"])
    expect(status.kind).toBe("fallback")
    expect(getAesBackend().igeDecrypt).toBe(nodeAesBackend.igeDecrypt)
  })

  test("matches the JS decryption when libcrypto is available", () => {
    const native = loadNativeIgeDecrypt()
    if (!("decrypt" in native)) {
      // Set REQUIRE_NATIVE_AES=1 where libcrypto must exist (the server image, Linux CI).
      if (process.env["REQUIRE_NATIVE_AES"] === "1") throw new Error(`native AES unavailable: ${native.reason}`)
      console.warn(`native AES unavailable here: ${native.reason}`)
      return
    }
    const key = new Uint8Array(randomBytes(32))
    const iv = new Uint8Array(randomBytes(32))
    const plaintext = new Uint8Array(randomBytes(512 * 1_024))
    const ciphertext = nodeAesBackend.igeEncrypt(plaintext, key, iv)
    const ivBefore = iv.slice()
    expect(Buffer.from(native.decrypt(ciphertext, key, iv)).equals(Buffer.from(plaintext))).toBe(true)
    // The caller's IV is never advanced.
    expect(Buffer.from(iv).equals(Buffer.from(ivBefore))).toBe(true)
    // Views at an odd byte offset leave every pointer OpenSSL sees unaligned.
    const unaligned = (bytes: Uint8Array) => {
      const backing = new Uint8Array(bytes.length + 7)
      backing.set(bytes, 7)
      return backing.subarray(7)
    }
    const shifted = nodeAesBackend.igeEncrypt(plaintext.subarray(0, 4_096), key, iv)
    expect(Buffer.from(native.decrypt(unaligned(shifted), unaligned(key), unaligned(iv)))
      .equals(Buffer.from(plaintext.subarray(0, 4_096)))).toBe(true)
    // Inputs the record layer never sends take the reference path.
    const odd = new Uint8Array(randomBytes(20))
    expect(Buffer.from(native.decrypt(odd, key, iv)).equals(Buffer.from(nodeAesBackend.igeDecrypt(odd, key, iv))))
      .toBe(true)
  })

  test("INLINE_NATIVE_AES=0 keeps the JS backend", () => {
    const previous = process.env["INLINE_NATIVE_AES"]
    process.env["INLINE_NATIVE_AES"] = "0"
    try {
      expect(installServerAesBackend()).toEqual({ kind: "fallback", reason: "disabled by INLINE_NATIVE_AES=0" })
      expect(getAesBackend().igeDecrypt).toBe(nodeAesBackend.igeDecrypt)
    } finally {
      if (previous === undefined) delete process.env["INLINE_NATIVE_AES"]
      else process.env["INLINE_NATIVE_AES"] = previous
    }
  })

  test("installs native decryption beside the JS encryption", () => {
    const status = installServerAesBackend()
    try {
      if (status.kind === "native") {
        expect(getAesBackend().name).toBe("node-crypto+openssl-ige")
        expect(getAesBackend().igeEncrypt).toBe(nodeAesBackend.igeEncrypt)
      }
    } finally {
      setAesBackend(nodeAesBackend)
    }
  })
})
