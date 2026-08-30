import { describe, expect, it } from "vitest"
import { getBearerToken, tokenHashHex } from "./auth"

describe("mcp auth helpers", () => {
  it("returns missing when authorization header is absent", () => {
    const req = new Request("http://localhost/mcp")
    expect(getBearerToken(req)).toEqual({ ok: false, error: { kind: "missing" } })
  })

  it("returns invalid format for non-bearer auth header", () => {
    const req = new Request("http://localhost/mcp", {
      headers: { authorization: "Token abc" },
    })
    expect(getBearerToken(req)).toEqual({ ok: false, error: { kind: "invalid_format" } })
  })

  it("extracts bearer token", () => {
    const req = new Request("http://localhost/mcp", {
      headers: { authorization: "Bearer abc123" },
    })
    expect(getBearerToken(req)).toEqual({ ok: true, token: "abc123" })
  })

  it("hashes tokens", async () => {
    expect(await tokenHashHex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  })

  it.each(["Bearer abc extra", "Bearer abc,def", "Bearer\tabc", "Bearer"])(
    "rejects ambiguous authorization material: %s", (authorization) => {
      expect(getBearerToken(new Request("http://localhost/mcp", { headers: { authorization } })))
        .toEqual({ ok: false, error: { kind: "invalid_format" } })
    },
  )

  it("accepts case-insensitive bearer with multiple separating spaces", () => {
    expect(getBearerToken(new Request("http://localhost/mcp", { headers: { authorization: "bearer  mcp_at_abc-123" } })))
      .toEqual({ ok: true, token: "mcp_at_abc-123" })
  })
})
