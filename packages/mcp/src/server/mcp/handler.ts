import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { createInlineMcpServer } from "./server"
import { McpSessionManager } from "./sessions"
import { getBearerToken, tokenHashHex } from "./auth"
import type { McpConfig } from "../config"
import type { Store } from "../store"
import { createInlineApi } from "../inline/inline-api"

const DEFAULT_REQUIRED_SCOPE = "messages:read spaces:read"

function json(status: number, body: unknown, headers?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      ...(headers ?? {}),
    },
  })
}

function wwwAuthHeader(params: { code: "invalid_token" | "insufficient_scope"; desc: string; resourceMetadataUrl: string; scope?: string }) {
  let h = `Bearer error="${params.code}", error_description="${params.desc}"`
  if (params.scope) h += `, scope="${params.scope}"`
  h += `, resource_metadata="${params.resourceMetadataUrl}"`
  return h
}

async function importAesKeyFromConfig(config: McpConfig): Promise<CryptoKey> {
  if (!config.tokenEncryptionKeyB64) throw new Error("missing MCP_TOKEN_ENCRYPTION_KEY_B64")
  const raw = Buffer.from(config.tokenEncryptionKeyB64, "base64")
  if (raw.byteLength !== 32) throw new Error("MCP_TOKEN_ENCRYPTION_KEY_B64 must be 32 bytes (base64)")
  return await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["decrypt"])
}

function base64UrlToBytes(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)
  return new Uint8Array(Buffer.from(padded, "base64"))
}

async function decryptInlineToken(config: McpConfig, enc: string): Promise<string> {
  const [v, ivB64, ctB64] = enc.split(".")
  if (v !== "v1" || !ivB64 || !ctB64) throw new Error("invalid encrypted token")
  const key = await importAesKeyFromConfig(config)
  const iv = base64UrlToBytes(ivB64)
  const ct = base64UrlToBytes(ctB64)
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ct)
  return new TextDecoder().decode(pt)
}

async function buildAuthInfo(config: McpConfig, store: Store, token: string): Promise<{ ok: true; auth: AuthInfo; grantId: string } | { ok: false; status: 401 | 403; body: unknown; headers: HeadersInit }> {
  const nowMs = Date.now()
  const hashHex = await tokenHashHex(token)
  const stored = store.getAccessToken(hashHex, nowMs)
  if (!stored || stored.revokedAtMs) {
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

  const grant = store.getGrant(stored.grantId)
  if (!grant || grant.revokedAtMs) {
    return {
      ok: false,
      status: 403,
      body: { error: "invalid_grant" },
      headers: {
        "www-authenticate": wwwAuthHeader({
          code: "insufficient_scope",
          desc: "Grant revoked",
          resourceMetadataUrl: `${config.issuer}/.well-known/oauth-protected-resource`,
          scope: grant?.scope || DEFAULT_REQUIRED_SCOPE,
        }),
      },
    }
  }

  const auth: AuthInfo = {
    token,
    clientId: grant.clientId,
    scopes: grant.scope.split(/\s+/).filter(Boolean),
    expiresAt: Math.floor(stored.expiresAtMs / 1000),
    resource: new URL(config.issuer),
    extra: {
      grantId: grant.id,
      inlineUserId: grant.inlineUserId.toString(),
      spaceIds: grant.spaceIds.map((s) => s.toString()),
    },
  }

  return { ok: true, auth, grantId: grant.id }
}

export const Mcp = {
  create(params: { config: McpConfig; store: Store }) {
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

          const authRes = await buildAuthInfo(params.config, params.store, bearer.token)
          if (!authRes.ok) {
            return json(authRes.status, authRes.body, authRes.headers)
          }

          const sessionId = req.headers.get("mcp-session-id")
          if (sessionId) {
            const existing = sessions.get(sessionId)
            if (!existing) {
              return json(404, { error: "unknown_session" })
            }
            if (existing.grantId !== authRes.grantId) {
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

          // No session header: this must be the initialization POST.
          // Transport will validate method/headers and reject non-initialize flows itself.
          const grant = params.store.getGrant(authRes.grantId)
          if (!grant) return json(403, { error: "invalid_grant" })

          const inlineToken = await decryptInlineToken(params.config, grant.inlineTokenEnc)
          const inline = createInlineApi({
            baseUrl: params.config.inlineApiBaseUrl,
            token: inlineToken,
            allowed: { allowedSpaceIds: grant.spaceIds },
          })

          const server = createInlineMcpServer({ grant, inline })

          const { transport } = sessions.createTransport({
            grantId: grant.id,
            nowMs: Date.now(),
            server,
            close: async () => {
              await inline.close()
            },
          })

          await server.connect(transport)
          return await transport.handleRequest(req, { authInfo: authRes.auth })
        } catch (error) {
          return json(500, { error: "mcp_internal_error" })
        }
      },
    }
  },
}
