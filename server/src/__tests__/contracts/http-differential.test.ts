import { describe, expect, test } from "bun:test"
import { compareHttpExecutors, normalizeHttpResponse } from "@in/server/effect-server/testing"

describe("HTTP differential foundation", () => {
  test("normalizes volatile values and redacts sensitive values before comparison", async () => {
    const legacy = () =>
      Response.json(
        { ok: true, token: "legacy-secret", nested: { value: 1 } },
        { headers: { "set-cookie": "session=legacy", "x-request-id": "legacy-id" } },
      )
    const effect = () =>
      Response.json(
        { nested: { value: 1 }, token: "legacy-secret", ok: true },
        { headers: { "set-cookie": "session=legacy", "x-request-id": "effect-id" } },
      )

    const result = await compareHttpExecutors(legacy, effect, new Request("http://inline.test/example"))

    expect(JSON.stringify(result.legacy)).not.toContain("legacy-secret")
    expect(JSON.stringify(result.legacy)).not.toContain("session=legacy")
    expect(result.legacy).toEqual(result.effect)
  })

  test("rejects unexplained contract differences without printing response bodies", async () => {
    const legacy = () => Response.json({ ok: true }, { status: 200 })
    const effect = () => Response.json({ ok: false }, { status: 409 })

    await expect(compareHttpExecutors(legacy, effect, new Request("http://inline.test/example"))).rejects.toThrow(
      /^HTTP contract mismatch \(legacy=[a-f0-9]{64}, effect=[a-f0-9]{64}\)$/,
    )
  })

  test("canonicalizes JSON object key order", async () => {
    const normalized = await normalizeHttpResponse(Response.json({ z: 1, a: { y: 2, b: 3 } }))

    expect(normalized.body).toEqual({ a: { b: 3, y: 2 }, z: 1 })
  })
})
