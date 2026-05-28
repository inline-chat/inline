import { describe, expect, test } from "bun:test"
import { getIp } from "./ip"

describe("getIp", () => {
  test("prefers Cloudflare and real IP headers before x-forwarded-for", () => {
    const request = new Request("http://localhost", {
      headers: {
        "cf-connecting-ip": "203.0.113.10",
        "x-real-ip": "203.0.113.11",
        "x-forwarded-for": "198.51.100.10, 198.51.100.11",
      },
    })

    expect(getIp(request, null)).toBe("203.0.113.10")
  })

  test("falls back to the first x-forwarded-for value", () => {
    const request = new Request("http://localhost", {
      headers: {
        "x-forwarded-for": "198.51.100.10, 198.51.100.11",
      },
    })

    expect(getIp(request, null)).toBe("198.51.100.10")
  })
})
