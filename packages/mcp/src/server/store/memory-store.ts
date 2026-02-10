import type {
  AuthCode,
  AuthRequest,
  Grant,
  RegisteredClient,
  StoredAccessToken,
  StoredRefreshToken,
  Store,
} from "./types"

export function createMemoryStore(): Store {
  const clients = new Map<string, RegisteredClient>()
  const authRequests = new Map<string, AuthRequest>()
  const grants = new Map<string, Grant>()
  const authCodes = new Map<string, AuthCode>()
  const accessTokens = new Map<string, StoredAccessToken>()
  const refreshTokens = new Map<string, StoredRefreshToken>()

  return {
    ensureSchema() {},

    cleanupExpired(nowMs) {
      for (const [id, ar] of authRequests) {
        if (ar.expiresAtMs <= nowMs) authRequests.delete(id)
      }
      for (const [code, ac] of authCodes) {
        if (ac.expiresAtMs <= nowMs) authCodes.delete(code)
      }
    },

    createClient({ redirectUris, clientName, nowMs }) {
      const clientId = crypto.randomUUID()
      const client: RegisteredClient = { clientId, redirectUris, clientName, createdAtMs: nowMs }
      clients.set(clientId, client)
      return client
    },
    getClient(clientId) {
      return clients.get(clientId) ?? null
    },

    createAuthRequest(input) {
      const ar: AuthRequest = {
        id: input.id,
        clientId: input.clientId,
        redirectUri: input.redirectUri,
        state: input.state,
        scope: input.scope,
        codeChallenge: input.codeChallenge,
        csrfToken: input.csrfToken,
        deviceId: input.deviceId,
        inlineUserId: null,
        email: null,
        inlineTokenEnc: null,
        createdAtMs: input.nowMs,
        expiresAtMs: input.expiresAtMs,
      }
      authRequests.set(input.id, ar)
      return ar
    },
    getAuthRequest(id, nowMs) {
      const ar = authRequests.get(id)
      if (!ar) return null
      if (ar.expiresAtMs <= nowMs) return null
      return ar
    },
    setAuthRequestEmail(id, email) {
      const ar = authRequests.get(id)
      if (!ar) return
      ar.email = email
    },
    setAuthRequestInlineTokenEnc(id, inlineTokenEnc) {
      const ar = authRequests.get(id)
      if (!ar) return
      ar.inlineTokenEnc = inlineTokenEnc
    },
    setAuthRequestInlineUserId(id, inlineUserId) {
      const ar = authRequests.get(id)
      if (!ar) return
      ar.inlineUserId = inlineUserId
    },
    deleteAuthRequest(id) {
      authRequests.delete(id)
    },

    createGrant(input) {
      const grant: Grant = {
        id: input.id,
        clientId: input.clientId,
        inlineUserId: input.inlineUserId,
        scope: input.scope,
        spaceIds: input.spaceIds,
        inlineTokenEnc: input.inlineTokenEnc,
        createdAtMs: input.nowMs,
        revokedAtMs: null,
      }
      grants.set(grant.id, grant)
      return grant
    },
    getGrant(grantId) {
      return grants.get(grantId) ?? null
    },

    createAuthCode(input) {
      const code: AuthCode = {
        code: input.code,
        grantId: input.grantId,
        clientId: input.clientId,
        redirectUri: input.redirectUri,
        codeChallenge: input.codeChallenge,
        usedAtMs: null,
        createdAtMs: input.nowMs,
        expiresAtMs: input.expiresAtMs,
      }
      authCodes.set(code.code, code)
      return code
    },
    getAuthCode(code, nowMs) {
      const ac = authCodes.get(code)
      if (!ac) return null
      if (ac.expiresAtMs <= nowMs) return null
      return ac
    },
    markAuthCodeUsed(code, nowMs) {
      const ac = authCodes.get(code)
      if (!ac) return
      ac.usedAtMs = nowMs
    },

    createAccessToken({ tokenHashHex, grantId, nowMs, expiresAtMs }) {
      accessTokens.set(tokenHashHex, { tokenHashHex, grantId, createdAtMs: nowMs, expiresAtMs, revokedAtMs: null })
    },
    getAccessToken(tokenHashHex, nowMs) {
      const at = accessTokens.get(tokenHashHex)
      if (!at) return null
      if (at.revokedAtMs != null) return null
      if (at.expiresAtMs <= nowMs) return null
      return at
    },

    createRefreshToken({ tokenHashHex, grantId, nowMs, expiresAtMs }) {
      refreshTokens.set(tokenHashHex, {
        tokenHashHex,
        grantId,
        createdAtMs: nowMs,
        expiresAtMs,
        revokedAtMs: null,
        replacedByHashHex: null,
      })
    },
    getRefreshToken(tokenHashHex, nowMs) {
      const rt = refreshTokens.get(tokenHashHex)
      if (!rt) return null
      if (rt.revokedAtMs != null) return null
      if (rt.expiresAtMs <= nowMs) return null
      return rt
    },
    revokeRefreshToken(tokenHashHex, nowMs, replacedByHashHex) {
      const rt = refreshTokens.get(tokenHashHex)
      if (!rt) return
      rt.revokedAtMs = nowMs
      rt.replacedByHashHex = replacedByHashHex
    },
  }
}
