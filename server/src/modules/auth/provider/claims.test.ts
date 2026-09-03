import { describe, expect, test } from "bun:test"
import { extractGoogleProviderClaims, isGoogleAuthoritativeEmail } from "./claims"

describe("Google provider claims", () => {
  test("ignores provider profile pictures", () => {
    const claims = extractGoogleProviderClaims({
      sub: "google-subject",
      email: "PERSON@GMAIL.COM",
      email_verified: true,
      given_name: " Hasti ",
      family_name: " Sarkobi ",
      picture: "https://lh3.googleusercontent.com/provider-avatar",
    })

    expect(claims).toEqual({
      provider: "google",
      subject: "google-subject",
      email: "person@gmail.com",
      authoritativeEmail: true,
      firstName: "Hasti",
      lastName: "Sarkobi",
    })
    expect(Object.hasOwn(claims, "photoUrl")).toBe(false)
  })
})

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
