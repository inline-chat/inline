import { describe, expect, it } from "bun:test"
import { shouldEnableServerSentry } from "./sentryRelease"

describe("server Sentry environment", () => {
  it("enables Sentry only in production", () => {
    expect(shouldEnableServerSentry("production")).toBe(true)
    expect(shouldEnableServerSentry("development")).toBe(false)
    expect(shouldEnableServerSentry("test")).toBe(false)
    expect(shouldEnableServerSentry("local")).toBe(false)
  })
})
