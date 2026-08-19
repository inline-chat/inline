import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { INLINE_PROTOCOL_PRODUCTION_PUBLIC_KEYS } from "./production-trust-roots.js"

describe("Inline Protocol production trust roots", () => {
  it("ships the exact overlapping release ring", () => {
    const canonical = JSON.parse(readFileSync(new URL(
      "../../../packages/protocol/trust-roots/inline-protocol-production.json",
      import.meta.url,
    ), "utf8")) as { rsaPublicKeyRing: unknown[] }
    expect(INLINE_PROTOCOL_PRODUCTION_PUBLIC_KEYS).toEqual(canonical.rsaPublicKeyRing)
  })
})
