import { describe, expect, test } from "bun:test"
import { CaptureAuthority } from "./authority.js"

const identity = { runId: "run", claimEpoch: 1, generation: 3 }
const grant = { identity: "inline-grid-user-7-membership", trackSid: "TR-mic", speakerUserId: "7", membershipId: "membership" }
const microphone = { identity: grant.identity, trackSid: grant.trackSid, kind: "audio", source: "microphone" } as const

function setup(expiresAtMs = 100_000) {
  let clock = 1_000
  const authority = new CaptureAuthority({ identity, requestedAtMs: 1_000, leaseMs: 5_000, expiresAtMs,
    microphones: [grant], now: () => clock })
  return { authority, advance: (time: number) => { clock = time } }
}

describe("verified capture authority", () => {
  test("initial connection authority grants no microphone until the API/publication join is installed", () => {
    const authority = new CaptureAuthority({ identity, requestedAtMs: 1000, leaseMs: 5000, expiresAtMs: 100_000,
      microphones: [], now: () => 1000 })
    expect(authority.microphone(identity, microphone)).toBeUndefined()
    authority.replaceMicrophones(identity, [grant])
    expect(authority.microphone(identity, microphone)?.membershipId).toBe("membership")
    authority.replaceMicrophones(identity, [])
    expect(authority.microphone(identity, microphone)).toBeUndefined()
  })
  test("invalid replacement is atomic and ninth microphone is rejected", () => {
    const { authority } = setup()
    expect(() => authority.replaceMicrophones(identity, [grant, grant])).toThrow("protocol")
    expect(authority.microphone(identity, microphone)?.speakerUserId).toBe("7")
    expect(() => authority.replaceMicrophones(identity, Array.from({ length: 9 }, (_, index) => ({ ...grant, trackSid: `TR-${index}` })))).toThrow("overflow")
    expect(authority.microphone(identity, microphone)?.speakerUserId).toBe("7")
  })
  test("exact microphone identity and track only; screen, prefix impersonation and stale claim denied", () => {
    const { authority } = setup()
    expect(authority.microphone(identity, microphone)?.speakerUserId).toBe("7")
    expect(authority.microphone(identity, { ...microphone, source: "screen" })).toBeUndefined()
    expect(authority.microphone(identity, { ...microphone, identity: "inline-grid-user-7-other" })).toBeUndefined()
    expect(authority.microphone(identity, { ...microphone, trackSid: "TR-old" })).toBeUndefined()
    expect(() => authority.microphone({ ...identity, claimEpoch: 2 }, microphone)).toThrow("protocol")
    authority.revoke(grant.trackSid)
    expect(authority.microphone(identity, microphone)).toBeUndefined()
  })
  test("delayed lease response counts from request start, and expiry cannot be resurrected", () => {
    const { authority, advance } = setup()
    advance(5_900)
    authority.renew(identity, 2_000, 5_000)
    advance(7_000)
    expect(() => authority.assertCurrent(identity)).toThrow("expired")
    expect(() => authority.renew(identity, 6_900, 5_000)).toThrow("stopped")
  })
  test("out-of-order renewals cannot extend a newer accepted deadline", () => {
    const { authority, advance } = setup()
    advance(3_000)
    authority.renew(identity, 3_000, 4_000)
    authority.renew(identity, 2_000, 20_000)
    advance(7_000)
    expect(() => authority.assertCurrent(identity)).toThrow("expired")
  })
  test("fixed run deadline is never extended by lease renewals", () => {
    const { authority, advance } = setup(6_000)
    advance(5_000)
    authority.renew(identity, 5_000, 5_000)
    advance(6_000)
    expect(() => authority.assertCurrent(identity)).toThrow("expired")
  })
  test("stop invalidates buffered frame authority permanently", () => {
    const { authority } = setup()
    authority.stop()
    expect(() => authority.microphone(identity, microphone)).toThrow("stopped")
  })
})
