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
})
