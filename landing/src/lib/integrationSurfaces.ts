export const INLINE_ORIGIN = "https://inline.chat"
export const INLINE_API_ORIGIN = "https://api.inline.chat"
export const INLINE_MCP_ORIGIN = "https://mcp.inline.chat"

export const CANONICAL_OPENAPI_SOURCE_URL = `${INLINE_API_ORIGIN}/bot-api-reference/json`
export const V1_OPENAPI_SOURCE_URL = `${INLINE_API_ORIGIN}/v1/reference/json`
export const MCP_CONNECT_URL = `${INLINE_MCP_ORIGIN}/mcp`
export const MCP_AUTHORIZATION_SERVER_URL = `${INLINE_API_ORIGIN}/.well-known/oauth-authorization-server`
export const INTEGRATIONS_DECLARATION_URL = `${INLINE_ORIGIN}/.well-known/integrations.json`

export const PUBLIC_JSON_HEADERS = {
  "cache-control": "public, max-age=300, s-maxage=3600, stale-while-revalidate=86400",
  "content-type": "application/json; charset=utf-8",
} as const

export const UNCACHED_JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
} as const

const declaredBasis = {
  via: "declared",
  source: INTEGRATIONS_DECLARATION_URL,
} as const

const inlineBearerCredentialId = "inline_bearer_token"
const inlineOauthCredentialId = "inline_mcp_oauth"

export const mcpServerCard = {
  url: MCP_CONNECT_URL,
  authentication: {
    type: "oauth2",
    authorization_server: MCP_AUTHORIZATION_SERVER_URL,
  },
} as const

export const integrationsDeclaration = {
  version: 3,
  summary:
    "Inline exposes a Bot HTTP API, a full Realtime WebSocket API and SDK, a hosted MCP server, and a CLI for work chat automation.",
  credentials: {
    [inlineBearerCredentialId]: {
      type: "bearer",
      label: "Inline bearer token",
      generateUrl: `${INLINE_ORIGIN}/docs/creating-a-bot`,
      setup:
        "Create or reveal a bot token in Inline, or run `inline auth login` for a user token. Send it as `Authorization: Bearer <token>` for HTTP APIs, or set `INLINE_TOKEN` for the CLI and Realtime SDK.",
    },
    [inlineOauthCredentialId]: {
      type: "oauth2",
      label: "Inline MCP OAuth",
      authorizationServer: MCP_AUTHORIZATION_SERVER_URL,
      setup:
        "Connect to the MCP server and complete Inline OAuth 2.1 with PKCE. Grant the requested MCP scopes and choose the spaces, DMs, and home threads the client may access.",
    },
  },
  surfaces: [
    {
      slug: "inline-bot-api",
      name: "Inline Bot HTTP API",
      type: "http",
      docs: `${INLINE_ORIGIN}/docs/bot-api`,
      spec: `${INLINE_ORIGIN}/openapi.json`,
      url: INLINE_API_ORIGIN,
      basis: declaredBasis,
      auth: {
        status: "required",
        entries: [
          {
            use: [
              {
                id: inlineBearerCredentialId,
                mechanics: {
                  source: "http",
                  in: "header",
                  headerName: "Authorization",
                  scheme: "Bearer",
                },
              },
            ],
            basis: declaredBasis,
          },
        ],
      },
    },
    {
      slug: "inline-http-api",
      name: "Inline HTTP API",
      type: "http",
      docs: `${INLINE_ORIGIN}/docs/developers`,
      spec: V1_OPENAPI_SOURCE_URL,
      url: INLINE_API_ORIGIN,
      basis: declaredBasis,
      auth: {
        status: "required",
        entries: [
          {
            use: [
              {
                id: inlineBearerCredentialId,
                mechanics: {
                  source: "http",
                  in: "header",
                  headerName: "Authorization",
                  scheme: "Bearer",
                },
              },
            ],
            basis: declaredBasis,
          },
        ],
      },
    },
    {
      slug: "inline-realtime-api",
      name: "Inline Realtime API",
      type: "websocket",
      docs: `${INLINE_ORIGIN}/docs/realtime-api`,
      url: "wss://api.inline.chat/realtime",
      package: "@inline-chat/realtime-sdk",
      basis: declaredBasis,
      auth: {
        status: "required",
        entries: [
          {
            use: [
              {
                id: inlineBearerCredentialId,
                mechanics: {
                  source: "websocket",
                  in: "connection_init",
                  fieldName: "token",
                },
              },
            ],
            basis: declaredBasis,
          },
        ],
      },
    },
    {
      slug: "inline-mcp-server",
      name: "Inline MCP server",
      type: "mcp",
      docs: `${INLINE_ORIGIN}/docs/mcp`,
      url: MCP_CONNECT_URL,
      transports: ["streamable-http"],
      basis: declaredBasis,
      auth: {
        status: "required",
        entries: [
          {
            use: [
              {
                id: inlineOauthCredentialId,
                mechanics: {
                  source: "oauth2",
                  authorizationServer: MCP_AUTHORIZATION_SERVER_URL,
                },
              },
            ],
            basis: declaredBasis,
          },
        ],
      },
    },
    {
      slug: "inline-cli",
      name: "Inline CLI",
      type: "cli",
      docs: `${INLINE_ORIGIN}/docs/cli`,
      url: `${INLINE_ORIGIN}/cli/install.sh`,
      command: "inline",
      install: {
        homebrew: "brew tap inline-chat/homebrew-inline && brew install --cask inline",
        script: "curl -fsSL https://inline.chat/cli/install.sh | sh",
      },
      basis: declaredBasis,
      auth: {
        status: "required",
        entries: [
          {
            use: [
              {
                id: inlineBearerCredentialId,
                mechanics: {
                  source: "environment",
                  variable: "INLINE_TOKEN",
                },
              },
            ],
            basis: declaredBasis,
          },
        ],
      },
    },
  ],
} as const

export async function fetchCanonicalOpenApiResponse(): Promise<Response> {
  let response: Response
  try {
    response = await fetch(CANONICAL_OPENAPI_SOURCE_URL, {
      headers: {
        accept: "application/json",
      },
    })
  } catch {
    return Response.json(
      { error: "openapi_source_unavailable" },
      {
        status: 502,
        headers: UNCACHED_JSON_HEADERS,
      },
    )
  }

  if (!response.ok) {
    return Response.json(
      { error: "openapi_source_unavailable", status: response.status },
      {
        status: 502,
        headers: UNCACHED_JSON_HEADERS,
      },
    )
  }

  let spec: unknown
  try {
    spec = await response.json()
  } catch {
    return Response.json(
      { error: "openapi_source_invalid_json" },
      {
        status: 502,
        headers: UNCACHED_JSON_HEADERS,
      },
    )
  }

  return Response.json(spec, {
    headers: PUBLIC_JSON_HEADERS,
  })
}

export async function fetchCanonicalOpenApiHeadResponse(): Promise<Response> {
  const response = await fetchCanonicalOpenApiResponse()
  return new Response(null, {
    status: response.status,
    headers: response.headers,
  })
}
