import { describe, expect, it } from "bun:test"
import { parseCredential, probeV3, serializeCredential, socketTarget, type V3Probe } from "./release-smoke-v3"

const credential = { key: Uint8Array.from({ length: 256 }, (_, index) => index), keyId: Uint8Array.from([1, 2, 3, 4, 5, 6, 7, 8]) }

function fake({ handshake = true, getMe = true } = {}) {
  const calls: string[] = []
  const open = async (ip?: string): Promise<V3Probe> => {
    calls.push(`open ${ip}`)
    return {
      handshake: async () => { calls.push("handshake"); if (!handshake) throw Object.assign(new Error("secret-bearing cause"), { code: "timeout" }) },
      getMe: async (value) => { calls.push(`getMe ${value.keyId.join("")}`); if (!getMe) throw new Error("Unexpected RPC response"); return 42n },
      close: async () => { calls.push("close") },
    }
  }
  return { open, calls }
}

describe("V3 release probe", () => {
  it("round-trips the permanent credential and rejects malformed values", () => {
    expect(parseCredential(serializeCredential(credential))).toEqual(credential)
    expect(parseCredential(undefined)).toBeUndefined()
    expect(parseCredential("")).toBeUndefined()
    for (const value of ["nope", "{}", JSON.stringify({ key: "AAAA", keyId: "AQIDBAUGBwg=" }), JSON.stringify({ key: Buffer.alloc(256).toString("base64"), keyId: "a b" })]) {
      expect(() => parseCredential(value)).toThrow("INLINE_SMOKE_V3_CREDENTIALS")
    }
  })

  it("dials the origin address while keeping api.inline.chat as Host, SNI and certificate identity", () => {
    const v4 = socketTarget("203.0.113.7")
    expect(v4.url).toBe("wss://203.0.113.7/realtime/v3")
    expect(v4.options).toMatchObject({ headers: { Host: "api.inline.chat" }, servername: "api.inline.chat", rejectUnauthorized: true })
    expect(socketTarget("2001:db8::7").url).toBe("wss://[2001:db8::7]/realtime/v3")
    expect(socketTarget().url).toBe("wss://api.inline.chat/realtime/v3")
    for (const ip of ["not-an-ip", "203.0.113.7:443"]) expect(() => socketTarget(ip)).toThrow("IPv4 or IPv6")
  })

  it("always runs the handshake, and calls getMe only with a credential", async () => {
    const without = fake()
    expect(await probeV3({ ip: "203.0.113.7", open: without.open })).toEqual([
      { name: "v3 handshake and ping", ok: true, detail: "temporary key exchanged; encrypted ping answered" },
      { name: "v3 getMe", ok: true, skipped: true, detail: "skipped: INLINE_SMOKE_V3_CREDENTIALS is not configured" },
    ])
    expect(without.calls).toEqual(["open 203.0.113.7", "handshake", "close"])
    const withCredential = fake()
    const checks = await probeV3({ ip: "203.0.113.7", credential, open: withCredential.open })
    expect(checks.at(-1)).toEqual({ name: "v3 getMe", ok: true, detail: "authenticated as user 42" })
    expect(withCredential.calls).toEqual(["open 203.0.113.7", "handshake", "getMe 12345678", "close"])
  })

  it("reports fixed failure classes, skips getMe after a failed handshake, and honours advisory mode", async () => {
    const broken = fake({ handshake: false })
    const checks = await probeV3({ ip: "203.0.113.7", credential, open: broken.open })
    expect(checks).toEqual([{ name: "v3 handshake and ping", ok: false, detail: "Inline Protocol timeout" }])
    expect(broken.calls).not.toContain("getMe 12345678")
    expect(broken.calls.at(-1)).toBe("close")
    expect((await probeV3({ credential, open: fake({ getMe: false }).open, advisory: true })).at(-1))
      .toEqual({ name: "v3 getMe", ok: false, detail: "Unexpected RPC response", advisory: true })
    const unreachable = await probeV3({ open: async () => { throw new Error("x".repeat(200)) } })
    expect(unreachable).toEqual([{ name: "v3 handshake and ping", ok: false, detail: "Inline Protocol failure" }])
  })
})
