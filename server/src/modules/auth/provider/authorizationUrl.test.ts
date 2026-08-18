import { describe, expect, it } from "bun:test"
import { applyAppleAuthorizationParameters } from "./authorizationUrl"

describe("Apple authorization URL", () => {
  it("uses form_post when requesting profile scopes", () => {
    const url = new URL(
      "https://appleid.apple.com/auth/authorize?scope=name%20email",
    )

    applyAppleAuthorizationParameters(url, "provider-nonce")

    expect(url.searchParams.get("nonce")).toBe("provider-nonce")
    expect(url.searchParams.get("response_mode")).toBe("form_post")
  })
})
