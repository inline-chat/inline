import { describe, expect, test } from "bun:test"
import { randomBytes } from "node:crypto"
import { sha1 } from "@noble/hashes/legacy"
import { sha256 } from "@noble/hashes/sha2"
import { bytesToHex, concatBytes, sha1Digest, sha256Digest } from "../src/secure/index.js"
import { digest, loadNativeDigest, makeNativeDigest, nativeDigest, portableDigest } from "../src/secure/digest.js"

const random = (length: number): Uint8Array => Uint8Array.from(randomBytes(length))
const ascii = (text: string): Uint8Array => new TextEncoder().encode(text)
/** An odd offset into a larger buffer, as record parsing hands out. */
const offsetView = (length: number): Uint8Array => random(length + 7).subarray(7)

const inputs: Array<[string, Uint8Array[]]> = [
  ["no parts", []],
  ["one empty part", [new Uint8Array(0)]],
  ["small", [ascii("abc")]],
  ["multi-part with empty parts", [ascii("a"), new Uint8Array(0), ascii("bc"), new Uint8Array(0)]],
  ["msg_key shape", [random(32), random(512 * 1024 + 48)]],
  ["AES key derivation shape", [random(16), random(36)]],
  ["offset views", [offsetView(13), offsetView(64), offsetView(4_097)]],
]

const noble = { sha1, sha256 } as const

describe("SHA digests", () => {
  test("Bun uses node:crypto", () => {
    expect(nativeDigest).toBeDefined()
    expect(digest).toBe(nativeDigest!)
  })

  test("native and portable digests are byte-identical", () => {
    for (const algorithm of ["sha1", "sha256"] as const) {
      for (const [, parts] of inputs) {
        const expected = noble[algorithm](concatBytes(...parts))
        const native = nativeDigest!(algorithm, parts)
        expect(bytesToHex(native)).toBe(bytesToHex(expected))
        expect(bytesToHex(portableDigest(algorithm, parts))).toBe(bytesToHex(expected))
        // Callers slice digests and expect copies, never aliasing Buffers.
        expect(native.constructor).toBe(Uint8Array)
      }
    }
  })

  test("the exported helpers match published vectors", () => {
    expect(bytesToHex(sha256Digest())).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    expect(bytesToHex(sha256Digest(ascii("ab"), ascii("c"))))
      .toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    expect(bytesToHex(sha1Digest(ascii("a"), new Uint8Array(0), ascii("bc"))))
      .toBe("a9993e364706816aba3e25717850c26c9cd0d89d")
  })

  test("hosts without node:crypto, or with a mismatched one, keep the portable path", () => {
    const host = process as unknown as { getBuiltinModule?: unknown }
    const original = host.getBuiltinModule
    try {
      host.getBuiltinModule = undefined
      expect(loadNativeDigest()).toBeUndefined()
      host.getBuiltinModule = () => undefined
      expect(loadNativeDigest()).toBeUndefined()
      host.getBuiltinModule = () => ({ createHash: () => ({ update: () => undefined, digest: () => new Uint8Array(32) }) })
      expect(loadNativeDigest()).toBeUndefined()
      host.getBuiltinModule = () => { throw new Error("unavailable") }
      expect(loadNativeDigest()).toBeUndefined()
    } finally {
      host.getBuiltinModule = original
    }
    expect(loadNativeDigest()).toBeDefined()
  })

  test("a native digest copies out of the host buffer", () => {
    const backing = new Uint8Array(64).fill(9)
    const native = makeNativeDigest(() => ({ update: () => undefined, digest: () => backing.subarray(16, 48) }))
    const result = native("sha256", [])
    backing.fill(0)
    expect(result.every((byte) => byte === 9)).toBeTrue()
    expect(result.byteOffset).toBe(0)
  })
})
