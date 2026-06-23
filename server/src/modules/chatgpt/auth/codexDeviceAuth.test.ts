import { describe, expect, test } from "bun:test"
import { OPENAI_AUTH_BASE_URL, OPENAI_CODEX_CLIENT_ID } from "@inline-chat/agent-chatgpt"
import { parseCredential, pollCodexDeviceAuth, startCodexDeviceAuth } from "./codexDeviceAuth"

describe("codex device auth", () => {
  test("starts and completes the OpenAI Codex device flow", async () => {
    const accessToken = jwt({
      exp: 1_770_000_000,
      "https://api.openai.com/profile": {
        email: "codex@example.com",
      },
      "https://api.openai.com/auth": {
        chatgpt_account_id: "acct-1",
        chatgpt_plan_type: "team",
      },
    })
    const calls: Array<{ url: string; body?: string }> = []
    const fetchFn = (async (input, init) => {
      const url = String(input)
      calls.push({ url, body: String(init?.body ?? "") })

      if (url.endsWith("/api/accounts/deviceauth/usercode")) {
        return json({
          device_auth_id: "device-1",
          user_code: "ABCD-EFGH",
          interval: 2,
        })
      }

      if (url.endsWith("/api/accounts/deviceauth/token")) {
        return json({
          authorization_code: "authorization-code",
          code_verifier: "code-verifier",
        })
      }

      if (url.endsWith("/oauth/token")) {
        return json({
          access_token: accessToken,
          refresh_token: "refresh-token",
          expires_in: 3600,
          token_type: "Bearer",
          scope: "openid profile",
        })
      }

      return new Response("unexpected", { status: 500 })
    }) as typeof fetch

    const prompt = await startCodexDeviceAuth({
      ownerUserId: 10,
      scope: { type: "user", userId: 10 },
      fetchFn,
    })

    expect(prompt).toMatchObject({
      verificationUrl: `${OPENAI_AUTH_BASE_URL}/codex/device`,
      userCode: "ABCD-EFGH",
      intervalSeconds: 2,
    })

    const result = await pollCodexDeviceAuth({
      ownerUserId: 10,
      pendingId: prompt.pendingId,
      fetchFn,
    })

    expect(result).toMatchObject({
      status: "connected",
      scope: { type: "user", userId: 10 },
      credential: {
        accessToken,
        refreshToken: "refresh-token",
        tokenType: "Bearer",
        scopes: ["openid", "profile"],
      },
      identity: {
        accountId: "acct-1",
        chatgptPlanType: "team",
        email: "codex@example.com",
        profileName: "codex@example.com",
      },
    })
    expect(calls.map((call) => call.url)).toEqual([
      `${OPENAI_AUTH_BASE_URL}/api/accounts/deviceauth/usercode`,
      `${OPENAI_AUTH_BASE_URL}/api/accounts/deviceauth/token`,
      `${OPENAI_AUTH_BASE_URL}/oauth/token`,
    ])
    expect(calls[0]!.body).toBe(JSON.stringify({ client_id: OPENAI_CODEX_CLIENT_ID }))
    expect(calls[2]!.body).toContain("grant_type=authorization_code")
    expect(calls[2]!.body).toContain("code=authorization-code")
  })

  test("does not let another user poll a pending authorization", async () => {
    const result = await pollCodexDeviceAuth({
      ownerUserId: 11,
      pendingId: "missing",
      fetchFn: (async () => new Response("unexpected", { status: 500 })) as unknown as typeof fetch,
    })

    expect(result).toEqual({
      status: "error",
      errorCode: "device_auth_not_found",
      errorMessage: "Device authorization was not found.",
    })
  })

  test("parses token credentials with absolute expiry fallback", () => {
    const token = jwt({ exp: 1_770_000_000 })
    expect(parseCredential(JSON.stringify({ access_token: token, refresh_token: "refresh" }))).toEqual({
      accessToken: token,
      refreshToken: "refresh",
      expiresAt: 1_770_000_000_000,
    })
  })
})

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  })
}

function jwt(payload: Record<string, unknown>): string {
  return [
    Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url"),
    Buffer.from(JSON.stringify(payload)).toString("base64url"),
    "signature",
  ].join(".")
}
