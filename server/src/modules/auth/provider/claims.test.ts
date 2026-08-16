import { describe, expect, test } from "bun:test"
import { isGoogleAuthoritativeEmail } from "./claims"

describe("Google authoritative email", () => {
  test("trusts a verified Gmail address", () => {
    expect(isGoogleAuthoritativeEmail("person@gmail.com", true, undefined)).toBe(true)
  })

  test("does not trust an unverified Gmail address", () => {
    expect(isGoogleAuthoritativeEmail("person@gmail.com", false, undefined)).toBe(false)
  })

  test("trusts a verified Google Workspace address with a hosted domain", () => {
    expect(isGoogleAuthoritativeEmail("person@example.com", true, "example.com")).toBe(true)
  })

  test("does not trust a verified non-Gmail address without a hosted domain", () => {
    expect(isGoogleAuthoritativeEmail("person@example.com", true, undefined)).toBe(false)
  })
})
