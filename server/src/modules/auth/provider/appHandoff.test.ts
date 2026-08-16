import { describe, expect, test } from "bun:test"
import {
  createAppCodeChallenge,
  isValidAppCodeChallenge,
  isValidAppCodeVerifier,
} from "./appHandoff"

describe("provider app handoff PKCE", () => {
  test("derives the RFC 7636 S256 example", () => {
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    expect(createAppCodeChallenge(verifier)).toBe("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  })

  test("accepts only correctly shaped challenges and verifiers", () => {
    const verifier = "a".repeat(43)
    expect(isValidAppCodeVerifier(verifier)).toBe(true)
    expect(isValidAppCodeVerifier("short")).toBe(false)
    expect(isValidAppCodeChallenge(createAppCodeChallenge(verifier))).toBe(true)
    expect(isValidAppCodeChallenge("not-a-challenge")).toBe(false)
  })
})
