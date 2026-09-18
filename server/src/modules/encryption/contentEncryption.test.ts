import { afterEach, describe, expect, it } from "bun:test"
import {
  assertContentEncryptionConfigured, CONTENT_PREFIX, ContentEncryptionError, contentLookup,
  openContent, openContentText, sealContent, sealContentText,
} from "./contentEncryption"

const originalKey = process.env["ENCRYPTION_KEY"]
const originalMode = process.env["CONTENT_ENCRYPTION_WRITES"]
afterEach(() => {
  for (const [name, value] of [["ENCRYPTION_KEY", originalKey], ["CONTENT_ENCRYPTION_WRITES", originalMode]]) {
    if (value === undefined) Reflect.deleteProperty(process.env, name!)
    else process.env[name!] = value
  }
})

describe("content storage cipher", () => {
  it("roundtrips empty, Unicode and marker-like text with randomized ciphertext", () => {
    for (const text of ["", "سلام 👨‍👩‍👧‍👦 café", `${CONTENT_PREFIX}not-ciphertext`]) {
      const a = sealContentText(text, "test.title")
      expect(a).not.toBe(sealContentText(text, "test.title"))
      expect(a.startsWith(CONTENT_PREFIX)).toBe(true)
      expect(openContentText(a, "test.title")).toBe(text)
    }
    const bytes = Buffer.from([0, 255, 2, 8])
    expect(openContent(sealContent(bytes, "test.waveform"), "test.waveform")).toEqual(bytes)
    expect(openContentText("legacy", "test.title")).toBe("legacy")
    expect(openContent(bytes, "test.waveform")).toEqual(bytes)
  })

  it("fails closed on wrong key, purpose, tampering, truncation and unknown versions", () => {
    const sealed = sealContent(Buffer.from("secret"), "a")
    expect(() => openContent(sealed, "b")).toThrow(ContentEncryptionError)
    const bad = Buffer.from(sealed)
    bad[bad.length - 1] = bad[bad.length - 1]! ^ 1
    expect(() => openContent(bad, "a")).toThrow(ContentEncryptionError)
    expect(() => openContent(sealed.subarray(0, sealed.length - 10), "a")).toThrow(ContentEncryptionError)
    expect(() => openContentText(`${CONTENT_PREFIX}bad!`, "a")).toThrow(ContentEncryptionError)
    expect(() => openContentText("inline-content:v99:x", "a")).toThrow(ContentEncryptionError)
    expect(() => openContent(Buffer.from("inline-content:v99:x"), "a")).toThrow(ContentEncryptionError)
    process.env["ENCRYPTION_KEY"] = "ab".repeat(32)
    expect(() => openContent(sealed, "a")).toThrow(ContentEncryptionError)
  })

  it("validates configuration and bounds without disclosing values", () => {
    const boundary = "a".repeat(1024 * 1024)
    expect(openContentText(sealContentText(boundary, "test"), "test")).toBe(boundary)
    expect(() => sealContent(Buffer.alloc(1024 * 1024 + 1), "test")).toThrow(ContentEncryptionError)
    expect(() => openContentText(CONTENT_PREFIX + "A".repeat(2 * 1024 * 1024), "test")).toThrow(ContentEncryptionError)
    process.env["CONTENT_ENCRYPTION_WRITES"] = "yes"
    expect(assertContentEncryptionConfigured).toThrow(ContentEncryptionError)
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    process.env["ENCRYPTION_KEY"] = "zz".repeat(32)
    expect(assertContentEncryptionConfigured).toThrow(ContentEncryptionError)
  })

  it("separates lookup purpose, scope, and value without exposing ordinary hashes", () => {
    const hash = contentLookup("title", ["space", 1], "name")
    expect(hash).toEqual(contentLookup("title", ["space", 1], "name"))
    expect(hash).not.toEqual(contentLookup("title", ["space", 2], "name"))
    expect(hash).not.toEqual(contentLookup("reaction", ["space", 1], "name"))
    expect(hash).not.toEqual(contentLookup("title", ["space", 1], "other"))
  })
})
