import { describe, expect, test } from "bun:test"
import { exchangeConnectorAuthorizationCode } from "./oauthTokenExchange"

describe("connector OAuth token exchange", () => {
  test("sends Notion's versioned JSON request with bounded I/O", async () => {
    let captured: { url: string; init?: RequestInit } | undefined
    const tokens = await exchangeConnectorAuthorizationCode({
      provider: "notion",
      code: "authorization-code",
      redirectUri: "https://dev.example.test/integrations/notion/callback",
      credentials: { clientId: "notion-id", clientSecret: "notion-secret" },
    }, async (url, init) => {
      captured = { url: String(url), init }
      return Response.json({ access_token: "notion-access", refresh_token: "refresh" })
    })

    expect(tokens?.data["access_token"]).toBe("notion-access")
    expect(captured?.url).toBe("https://api.notion.com/v1/oauth/token")
    expect(captured?.init?.headers).toMatchObject({
      "Content-Type": "application/json",
      "Notion-Version": "2026-03-11",
    })
    expect(captured?.init?.signal).toBeInstanceOf(AbortSignal)
    expect(JSON.parse(String(captured?.init?.body))).toMatchObject({
      grant_type: "authorization_code",
      code: "authorization-code",
      redirect_uri: "https://dev.example.test/integrations/notion/callback",
    })
  })

  test("sends Linear's form request to the matching redirect URI", async () => {
    let captured: { url: string; init?: RequestInit } | undefined
    const tokens = await exchangeConnectorAuthorizationCode({
      provider: "linear",
      code: "authorization-code",
      redirectUri: "https://dev.example.test/integrations/linear/callback",
      credentials: { clientId: "linear-id", clientSecret: "linear-secret" },
    }, async (url, init) => {
      captured = { url: String(url), init }
      return Response.json({ access_token: "linear-access" })
    })

    expect(tokens?.data["access_token"]).toBe("linear-access")
    expect(captured?.url).toBe("https://api.linear.app/oauth/token")
    expect(String(captured?.init?.body)).toContain("client_id=linear-id")
    expect(String(captured?.init?.body)).toContain(
      "redirect_uri=https%3A%2F%2Fdev.example.test%2Fintegrations%2Flinear%2Fcallback",
    )
    expect(captured?.init?.signal).toBeInstanceOf(AbortSignal)
  })
})
