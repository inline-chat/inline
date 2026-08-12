import type { ConnectorOAuthCredentials } from "./connectorOAuthCredentials"
import type { ConnectorOAuthRedirectProvider } from "./connectorOAuthRedirectUri"

const NOTION_API_VERSION = "2026-03-11"

type OAuthTokenRequest = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>

export async function exchangeConnectorAuthorizationCode(
  input: {
    provider: ConnectorOAuthRedirectProvider
    code: string
    redirectUri: string
    credentials: ConnectorOAuthCredentials
  },
  request: OAuthTokenRequest = fetch,
): Promise<{ data: Record<string, unknown> } | null> {
  const endpoint = input.provider === "linear"
    ? "https://api.linear.app/oauth/token"
    : "https://api.notion.com/v1/oauth/token"
  const response = await request(endpoint, tokenRequest(input))
  if (!response.ok) {
    await response.body?.cancel()
    return null
  }
  const data: unknown = await response.json()
  if (
    data === null
    || typeof data !== "object"
    || Array.isArray(data)
    || typeof (data as Record<string, unknown>)["access_token"] !== "string"
  ) return null
  return { data: data as Record<string, unknown> }
}

function tokenRequest(input: {
  provider: ConnectorOAuthRedirectProvider
  code: string
  redirectUri: string
  credentials: ConnectorOAuthCredentials
}): RequestInit {
  if (input.provider === "linear") {
    return {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code: input.code,
        redirect_uri: input.redirectUri,
        client_id: input.credentials.clientId,
        client_secret: input.credentials.clientSecret,
      }),
      signal: AbortSignal.timeout(10_000),
    }
  }

  const authorization = Buffer.from(
    `${input.credentials.clientId}:${input.credentials.clientSecret}`,
    "utf8",
  ).toString("base64")
  return {
    method: "POST",
    headers: {
      Authorization: `Basic ${authorization}`,
      "Content-Type": "application/json",
      "Notion-Version": NOTION_API_VERSION,
    },
    body: JSON.stringify({
      grant_type: "authorization_code",
      code: input.code,
      redirect_uri: input.redirectUri,
    }),
    signal: AbortSignal.timeout(10_000),
  }
}
