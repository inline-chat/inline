import { describe, expect, test } from "bun:test"
import { shouldRefreshOAuthToken } from "./oauthTokenLifecycle"

describe("OAuth token lifecycle", () => {
  const obtainedAt = new Date("2026-08-12T00:00:00Z")

  test("refreshes an expiring token before it becomes unusable", () => {
    expect(shouldRefreshOAuthToken(
      { access_token: "token", expires_in: 3_600 },
      obtainedAt,
      new Date("2026-08-12T00:56:00Z"),
    )).toBe(true)
  })

  test("keeps a fresh token and a provider token without expiry metadata", () => {
    expect(shouldRefreshOAuthToken(
      { access_token: "token", expires_in: 3_600 },
      obtainedAt,
      new Date("2026-08-12T00:10:00Z"),
    )).toBe(false)
    expect(shouldRefreshOAuthToken(
      { access_token: "token" },
      obtainedAt,
      new Date("2027-08-12T00:00:00Z"),
    )).toBe(false)
  })

  test("refreshes when the access token is absent", () => {
    expect(shouldRefreshOAuthToken(
      { refresh_token: "refresh" },
      obtainedAt,
      obtainedAt,
    )).toBe(true)
  })
})
