import { describe, expect, test } from "bun:test"
import { loadInlineProtocolConfiguration } from "./config"

describe("Inline Protocol configuration", () => {
  test("requires an explicit writer switch and replay ring while allowing reader-first rollout", () => {
    const ring = JSON.stringify({ activeId: "test", keys: { test: Buffer.alloc(32, 1).toString("base64") } })
    const base = { NODE_ENV: "production", INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON: "[]",
      INLINE_PROTOCOL_AUTH_KEY_KEK_RING_JSON: ring, INLINE_PROTOCOL_AUTH_CODE_PEPPER_RING_JSON: ring }
    expect(loadInlineProtocolConfiguration(base)).toMatchObject({ encryptReplayResults: false })
    expect(loadInlineProtocolConfiguration({ ...base, INLINE_PROTOCOL_REPLAY_KEY_RING_JSON: ring }))
      .toMatchObject({ encryptReplayResults: false, replayResultKeyRing: { activeId: "test" } })
    expect(() => loadInlineProtocolConfiguration({ ...base, INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS: "true" })).toThrow()
    expect(() => loadInlineProtocolConfiguration({ ...base, INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS: "yes" })).toThrow()
    expect(loadInlineProtocolConfiguration({ ...base, INLINE_PROTOCOL_REPLAY_KEY_RING_JSON: ring, INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS: "true" }))
      .toMatchObject({ encryptReplayResults: true })
  })
  test("is disabled without credentials only outside production", () => {
    expect(loadInlineProtocolConfiguration({ NODE_ENV: "development" })).toEqual({ enabled: false })
    expect(() => loadInlineProtocolConfiguration({ NODE_ENV: "production" })).toThrow()
  })

  test("enables automatically when credentials are present and rejects partial configuration", () => {
    expect(() => loadInlineProtocolConfiguration({
      NODE_ENV: "development",
      INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON: "[]",
    })).toThrow()
    const value = Buffer.alloc(32, 1).toString("base64")
    const ring = JSON.stringify({ activeId: "key1", keys: { key1: value } })
    expect(loadInlineProtocolConfiguration({
      NODE_ENV: "production",
      INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON: "[]",
      INLINE_PROTOCOL_AUTH_KEY_KEK_RING_JSON: ring,
      INLINE_PROTOCOL_AUTH_CODE_PEPPER_RING_JSON: ring,
    })).toMatchObject({ enabled: true, requireCanonicalPublicRing: true })
    expect(loadInlineProtocolConfiguration({
      NODE_ENV: "development",
      INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON: "[]",
      INLINE_PROTOCOL_AUTH_KEY_KEK_RING_JSON: ring,
      INLINE_PROTOCOL_AUTH_CODE_PEPPER_RING_JSON: ring,
    })).toMatchObject({ enabled: true, requireCanonicalPublicRing: false })
  })
})
