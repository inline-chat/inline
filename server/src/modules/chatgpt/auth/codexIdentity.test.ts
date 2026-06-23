import { describe, expect, test } from "bun:test"
import { resolveCodexAccessTokenExpiry, resolveCodexAuthIdentity } from "./codexIdentity"

describe("codex identity", () => {
  test("extracts expiry and ChatGPT metadata from Codex access token payload", () => {
    const token = jwt({
      exp: "1770000000",
      "https://api.openai.com/profile": {
        email: "  user@example.com ",
      },
      "https://api.openai.com/auth": {
        chatgpt_account_id: "account-1",
        chatgpt_plan_type: "plus",
      },
    })

    expect(resolveCodexAccessTokenExpiry(token)).toBe(1_770_000_000_000)
    expect(resolveCodexAuthIdentity({ accessToken: token })).toEqual({
      accountId: "account-1",
      chatgptPlanType: "plus",
      email: "user@example.com",
      profileName: "user@example.com",
    })
  })

  test("falls back to stable pseudonymous profile name without email", () => {
    const token = jwt({
      "https://api.openai.com/auth": {
        chatgpt_account_user_id: "user-1",
      },
    })

    expect(resolveCodexAuthIdentity({ accessToken: token })).toEqual({
      profileName: `id-${Buffer.from("user-1").toString("base64url")}`,
    })
  })

  test("ignores malformed access tokens", () => {
    expect(resolveCodexAccessTokenExpiry("not-a-jwt")).toBeUndefined()
    expect(resolveCodexAuthIdentity({ accessToken: "not-a-jwt", email: "fallback@example.com" })).toEqual({
      email: "fallback@example.com",
      profileName: "fallback@example.com",
    })
  })
})

function jwt(payload: Record<string, unknown>): string {
  return [
    Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url"),
    Buffer.from(JSON.stringify(payload)).toString("base64url"),
    "signature",
  ].join(".")
}
