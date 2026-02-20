export type RegisteredClient = {
  clientId: string
  redirectUris: string[]
  clientName: string | null
  createdAtMs: number
}

export type AuthRequest = {
  id: string
  clientId: string
  redirectUri: string
  state: string
  scope: string
  codeChallenge: string
  csrfToken: string
  deviceId: string
  inlineUserId: bigint | null
  email: string | null
  inlineTokenEnc: string | null
  createdAtMs: number
  expiresAtMs: number
}

export type Grant = {
  id: string
  clientId: string
  inlineUserId: bigint
  scope: string
  spaceIds: bigint[]
  inlineTokenEnc: string
  createdAtMs: number
  revokedAtMs: number | null
}

export type AuthCode = {
  code: string
  grantId: string
  clientId: string
  redirectUri: string
  codeChallenge: string
  usedAtMs: number | null
  createdAtMs: number
  expiresAtMs: number
}

export type StoredAccessToken = {
  tokenHashHex: string
  grantId: string
  createdAtMs: number
  expiresAtMs: number
  revokedAtMs: number | null
}

export type StoredRefreshToken = {
  tokenHashHex: string
  grantId: string
  createdAtMs: number
  expiresAtMs: number
  revokedAtMs: number | null
  replacedByHashHex: string | null
}

export type RateLimitResult = {
  allowed: boolean
  retryAfterSeconds: number
}

export type Store = {
  ensureSchema(): void
  cleanupExpired(nowMs: number): void

  consumeRateLimit(input: { key: string; nowMs: number; windowMs: number; max: number }): RateLimitResult

  createClient(input: { redirectUris: string[]; clientName: string | null; nowMs: number }): RegisteredClient
  getClient(clientId: string): RegisteredClient | null

  createAuthRequest(input: {
    id: string
    clientId: string
    redirectUri: string
    state: string
    scope: string
    codeChallenge: string
    csrfToken: string
    deviceId: string
    nowMs: number
    expiresAtMs: number
  }): AuthRequest
  getAuthRequest(id: string, nowMs: number): AuthRequest | null
  setAuthRequestEmail(id: string, email: string): void
  setAuthRequestInlineTokenEnc(id: string, inlineTokenEnc: string): void
  setAuthRequestInlineUserId(id: string, inlineUserId: bigint): void
  deleteAuthRequest(id: string): void

  createGrant(input: {
    id: string
    clientId: string
    inlineUserId: bigint
    scope: string
    spaceIds: bigint[]
    inlineTokenEnc: string
    nowMs: number
  }): Grant
  getGrant(grantId: string): Grant | null
  revokeGrant(grantId: string, nowMs: number): void

  createAuthCode(input: {
    code: string
    grantId: string
    clientId: string
    redirectUri: string
    codeChallenge: string
    nowMs: number
    expiresAtMs: number
  }): AuthCode
  getAuthCode(code: string, nowMs: number): AuthCode | null
  markAuthCodeUsed(code: string, nowMs: number): void

  createAccessToken(input: { tokenHashHex: string; grantId: string; nowMs: number; expiresAtMs: number }): void
  getAccessToken(tokenHashHex: string, nowMs: number): StoredAccessToken | null

  createRefreshToken(input: { tokenHashHex: string; grantId: string; nowMs: number; expiresAtMs: number }): void
  getRefreshToken(tokenHashHex: string, nowMs: number): StoredRefreshToken | null
  revokeRefreshToken(tokenHashHex: string, nowMs: number, replacedByHashHex: string | null): void
  revokeRefreshTokensByGrant(grantId: string, nowMs: number): void
  findGrantIdByTokenHash(tokenHashHex: string): string | null
}
