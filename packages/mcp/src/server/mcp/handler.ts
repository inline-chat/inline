import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { MCP_DEFAULT_SCOPE } from "@inline-chat/oauth-core"
import { createInlineMcpServer } from "./server"
import { McpSessionManager } from "./sessions"
import { getBearerToken } from "./auth"
import type { McpConfig } from "../config"
import { createInlineApi } from "../inline/inline-api"
import type { McpGrant } from "./grant"

const DEFAULT_REQUIRED_SCOPE = MCP_DEFAULT_SCOPE

type IntrospectionSuccess = {
  active: true
  grant_id: string
  client_id: string
  scope: string
  exp: number
  inline_user_id: string
  space_ids: string[]
  allow_dms: boolean
  allow_home_threads: boolean
  inline_token: string
}

function json(status: number, body: unknown, headers?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      ...(headers ?? {}),
    },
  })
}

function wwwAuthHeader(params: {
  code: "invalid_token" | "insufficient_scope"
  desc: string
  resourceMetadataUrl: string
  scope?: string
}): string {
  let header = `Bearer error=\"${params.code}\", error_description=\"${params.desc}\"`
  if (params.scope) header += `, scope=\"${params.scope}\"`
  header += `, resource_metadata=\"${params.resourceMetadataUrl}\"`
  return header
}

function parseIntrospectionPayload(raw: unknown): IntrospectionSuccess | null {
  if (!raw || typeof raw !== "object") return null
  const data = raw as Record<string, unknown>

  if (data["active"] !== true) return null
  if (typeof data["grant_id"] !== "string") return null
  if (typeof data["client_id"] !== "string") return null
  if (typeof data["scope"] !== "string") return null
  if (typeof data["exp"] !== "number") return null
  if (typeof data["inline_user_id"] !== "string") return null
  if (
    !Array.isArray(data["space_ids"]) ||
    !data["space_ids"].every((value) => typeof value === "string" && /^-?\d+$/.test(value))
  ) {
    return null
  }
  if (typeof data["allow_dms"] !== "boolean") return null
  if (typeof data["allow_home_threads"] !== "boolean") return null
  if (typeof data["inline_token"] !== "string" || data["inline_token"].trim().length === 0) return null

  return {
    active: true,
    grant_id: data["grant_id"],
    client_id: data["client_id"],
    scope: data["scope"],
    exp: data["exp"],
    inline_user_id: data["inline_user_id"],
    space_ids: data["space_ids"],
    allow_dms: data["allow_dms"],
    allow_home_threads: data["allow_home_threads"],
    inline_token: data["inline_token"],
  }
}

async function introspectAccessToken(
  config: McpConfig,
  token: string,
): Promise<
  | {
      ok: true
      introspection: IntrospectionSuccess
    }
  | {
      ok: false
      status: 401 | 500 | 502
      body: unknown
      headers?: HeadersInit
    }
> {
  if (!config.oauthInternalSharedSecret) {
    return {
      ok: false,
      status: 500,
      body: { error: "mcp_oauth_not_configured" },
    }
  }

  let response: Response
  try {
    response = await fetch(config.oauthIntrospectionUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-inline-mcp-secret": config.oauthInternalSharedSecret,
      },
      body: JSON.stringify({ token }),
    })
  } catch {
    return {
      ok: false,
      status: 502,
      body: { error: "oauth_introspection_unavailable" },
    }
  }

  if (response.status === 401 || response.status === 403) {
    return {
      ok: false,
      status: 401,
      body: { error: "invalid_token" },
      headers: {
        "www-authenticate": wwwAuthHeader({
          code: "invalid_token",
          desc: "Invalid access token",
          resourceMetadataUrl: `${config.issuer}/.well-known/oauth-protected-resource`,
          scope: DEFAULT_REQUIRED_SCOPE,
        }),
      },
    }
  }

  if (!response.ok) {
    return {
      ok: false,
      status: 502,
      body: { error: "oauth_introspection_failed" },
    }
  }

  let payload: unknown
  try {
    payload = await response.json()
  } catch {
    return {
      ok: false,
      status: 502,
      body: { error: "oauth_introspection_invalid_response" },
    }
  }

  const introspection = parseIntrospectionPayload(payload)
  if (!introspection) {
    return {
      ok: false,
      status: 401,
      body: { error: "invalid_token" },
      headers: {
        "www-authenticate": wwwAuthHeader({
          code: "invalid_token",
          desc: "Invalid access token",
          resourceMetadataUrl: `${config.issuer}/.well-known/oauth-protected-resource`,
          scope: DEFAULT_REQUIRED_SCOPE,
        }),
      },
    }
  }

  return {
    ok: true,
    introspection,
  }
}

async function buildAuthInfo(
  config: McpConfig,
  token: string,
): Promise<
  | {
      ok: true
      auth: AuthInfo
      grant: McpGrant
      inlineToken: string
    }
  | {
      ok: false
      status: 401 | 500 | 502
      body: unknown
      headers?: HeadersInit
    }
> {
  const introspectionRes = await introspectAccessToken(config, token)
  if (!introspectionRes.ok) {
    return introspectionRes
  }

  let inlineUserId: bigint
  try {
    inlineUserId = BigInt(introspectionRes.introspection.inline_user_id)
  } catch {
    return {
      ok: false,
      status: 502,
      body: { error: "oauth_introspection_invalid_user" },
    }
  }

  const grant: McpGrant = {
    id: introspectionRes.introspection.grant_id,
    clientId: introspectionRes.introspection.client_id,
    inlineUserId,
    scope: introspectionRes.introspection.scope,
    spaceIds: introspectionRes.introspection.space_ids.map((spaceId) => BigInt(spaceId)),
    allowDms: introspectionRes.introspection.allow_dms,
    allowHomeThreads: introspectionRes.introspection.allow_home_threads,
  }

  const auth: AuthInfo = {
    token,
    clientId: grant.clientId,
    scopes: grant.scope.split(/\s+/).filter(Boolean),
    expiresAt: introspectionRes.introspection.exp,
    resource: new URL(config.issuer),
    extra: {
      grantId: grant.id,
      inlineUserId: grant.inlineUserId.toString(),
      spaceIds: grant.spaceIds.map((spaceId) => spaceId.toString()),
      allowDms: grant.allowDms,
      allowHomeThreads: grant.allowHomeThreads,
    },
  }

  return {
    ok: true,
    auth,
    grant,
    inlineToken: introspectionRes.introspection.inline_token,
  }
}

export const Mcp = {
  create(params: { config: McpConfig }) {
    const sessions = new McpSessionManager()

    return {
      async handle(req: Request, url: URL): Promise<Response | null> {
        if (url.pathname !== "/mcp") return null

        try {
          const bearer = getBearerToken(req)
          if (!bearer.ok) {
            const missing = bearer.error.kind === "missing"
            return json(
              401,
              { error: missing ? "missing_authorization" : "invalid_authorization" },
              {
                "www-authenticate": wwwAuthHeader({
                  code: "invalid_token",
                  desc: missing ? "Missing Authorization header" : "Authorization must be Bearer <token>",
                  resourceMetadataUrl: `${params.config.issuer}/.well-known/oauth-protected-resource`,
                  scope: DEFAULT_REQUIRED_SCOPE,
                }),
              },
            )
          }

          const authRes = await buildAuthInfo(params.config, bearer.token)
          if (!authRes.ok) {
            return json(authRes.status, authRes.body, authRes.headers)
          }

          const sessionId = req.headers.get("mcp-session-id")
          if (sessionId) {
            const existing = sessions.get(sessionId)
            if (!existing) {
              return json(404, { error: "unknown_session" })
            }

            if (existing.grantId !== authRes.grant.id) {
              return json(
                403,
                { error: "session_grant_mismatch" },
                {
                  "www-authenticate": wwwAuthHeader({
                    code: "insufficient_scope",
                    desc: "Session does not belong to this grant",
                    resourceMetadataUrl: `${params.config.issuer}/.well-known/oauth-protected-resource`,
                    scope: authRes.auth.scopes.length > 0 ? authRes.auth.scopes.join(" ") : DEFAULT_REQUIRED_SCOPE,
                  }),
                },
              )
            }

            sessions.touch(sessionId, Date.now())
            return await existing.transport.handleRequest(req, { authInfo: authRes.auth })
          }

          const inline = createInlineApi({
            baseUrl: params.config.inlineApiBaseUrl,
            token: authRes.inlineToken,
            allowed: {
              allowedSpaceIds: authRes.grant.spaceIds,
              allowDms: authRes.grant.allowDms,
              allowHomeThreads: authRes.grant.allowHomeThreads,
            },
          })

          const server = createInlineMcpServer({
            grant: authRes.grant,
            inline,
          })

          const { transport } = sessions.createTransport({
            grantId: authRes.grant.id,
            nowMs: Date.now(),
            server,
            close: async () => {
              await inline.close()
            },
          })

          await server.connect(transport)
          return await transport.handleRequest(req, { authInfo: authRes.auth })
        } catch {
          return json(500, { error: "mcp_internal_error" })
        }
      },
    }
  },
}
