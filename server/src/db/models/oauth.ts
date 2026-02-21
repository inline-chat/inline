import { db } from "@in/server/db"
import {
  oauthAccessTokens,
  oauthAuthCodes,
  oauthAuthRequests,
  oauthClients,
  oauthGrants,
  oauthRefreshTokens,
} from "@in/server/db/schema/oauth"
import { and, eq, gt, isNull, or, sql } from "drizzle-orm"

export type OauthRegisteredClient = {
  clientId: string
  redirectUris: string[]
  clientName: string | null
  createdAtMs: number
}

export type OauthAuthRequest = {
  id: string
  clientId: string
  redirectUri: string
  state: string
  scope: string
  codeChallenge: string
  csrfToken: string
  deviceId: string
  inlineUserId: number | null
  email: string | null
  challengeToken: string | null
  inlineTokenEncrypted: Buffer | null
  createdAtMs: number
  expiresAtMs: number
}

export type OauthGrant = {
  id: string
  clientId: string
  inlineUserId: number
  scope: string
  spaceIds: bigint[]
  allowDms: boolean
  allowHomeThreads: boolean
  inlineTokenEncrypted: Buffer
  createdAtMs: number
  revokedAtMs: number | null
}

export type OauthAuthCode = {
  code: string
  grantId: string
  clientId: string
  redirectUri: string
  codeChallenge: string
  usedAtMs: number | null
  createdAtMs: number
  expiresAtMs: number
}

export type OauthAccessToken = {
  tokenHash: string
  grantId: string
  createdAtMs: number
  expiresAtMs: number
  revokedAtMs: number | null
}

export type OauthRefreshToken = {
  tokenHash: string
  grantId: string
  replacedByHash: string | null
  createdAtMs: number
  expiresAtMs: number
  revokedAtMs: number | null
}

function decodeJsonStringArray(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  return raw.filter((value): value is string => typeof value === "string")
}

function toMs(date: Date | null): number | null {
  return date ? date.getTime() : null
}

function toDate(ms: number): Date {
  return new Date(ms)
}

function mapClient(row: typeof oauthClients.$inferSelect): OauthRegisteredClient {
  return {
    clientId: row.clientId,
    redirectUris: decodeJsonStringArray(JSON.parse(row.redirectUrisJson)),
    clientName: row.clientName,
    createdAtMs: row.date.getTime(),
  }
}

function mapAuthRequest(row: typeof oauthAuthRequests.$inferSelect): OauthAuthRequest {
  return {
    id: row.id,
    clientId: row.clientId,
    redirectUri: row.redirectUri,
    state: row.state,
    scope: row.scope,
    codeChallenge: row.codeChallenge,
    csrfToken: row.csrfToken,
    deviceId: row.deviceId,
    inlineUserId: row.inlineUserId,
    email: row.email,
    challengeToken: row.challengeToken,
    inlineTokenEncrypted: row.inlineTokenEncrypted,
    createdAtMs: row.date.getTime(),
    expiresAtMs: row.expiresAt.getTime(),
  }
}

function mapGrant(row: typeof oauthGrants.$inferSelect): OauthGrant {
  const spaceIdsRaw = Array.isArray(row.spaceIdsJson) ? row.spaceIdsJson : []
  return {
    id: row.id,
    clientId: row.clientId,
    inlineUserId: row.inlineUserId,
    scope: row.scope,
    spaceIds: spaceIdsRaw.map((value) => BigInt(value)),
    allowDms: row.allowDms,
    allowHomeThreads: row.allowHomeThreads,
    inlineTokenEncrypted: row.inlineTokenEncrypted,
    createdAtMs: row.date.getTime(),
    revokedAtMs: toMs(row.revokedAt),
  }
}

function mapAuthCode(row: typeof oauthAuthCodes.$inferSelect): OauthAuthCode {
  return {
    code: row.code,
    grantId: row.grantId,
    clientId: row.clientId,
    redirectUri: row.redirectUri,
    codeChallenge: row.codeChallenge,
    usedAtMs: toMs(row.usedAt),
    createdAtMs: row.date.getTime(),
    expiresAtMs: row.expiresAt.getTime(),
  }
}

function mapAccessToken(row: typeof oauthAccessTokens.$inferSelect): OauthAccessToken {
  return {
    tokenHash: row.tokenHash,
    grantId: row.grantId,
    createdAtMs: row.date.getTime(),
    expiresAtMs: row.expiresAt.getTime(),
    revokedAtMs: toMs(row.revokedAt),
  }
}

function mapRefreshToken(row: typeof oauthRefreshTokens.$inferSelect): OauthRefreshToken {
  return {
    tokenHash: row.tokenHash,
    grantId: row.grantId,
    replacedByHash: row.replacedByHash,
    createdAtMs: row.date.getTime(),
    expiresAtMs: row.expiresAt.getTime(),
    revokedAtMs: toMs(row.revokedAt),
  }
}

export const OauthModel = {
  async cleanupExpired(nowMs: number): Promise<void> {
    const now = toDate(nowMs)
    await Promise.all([
      db.delete(oauthAuthRequests).where(sql`${oauthAuthRequests.expiresAt} <= ${now}`),
      db.delete(oauthAuthCodes).where(sql`${oauthAuthCodes.expiresAt} <= ${now}`),
      db.delete(oauthAccessTokens).where(sql`${oauthAccessTokens.expiresAt} <= ${now}`),
      db.delete(oauthRefreshTokens).where(sql`${oauthRefreshTokens.expiresAt} <= ${now}`),
    ])
  },

  async createClient(input: {
    clientId: string
    redirectUris: string[]
    clientName: string | null
    nowMs: number
  }): Promise<OauthRegisteredClient> {
    const [inserted] = await db
      .insert(oauthClients)
      .values({
        clientId: input.clientId,
        redirectUrisJson: JSON.stringify(input.redirectUris),
        clientName: input.clientName,
        date: toDate(input.nowMs),
      })
      .returning()

    if (!inserted) {
      throw new Error("failed to create oauth client")
    }

    return mapClient(inserted)
  },

  async getClient(clientId: string): Promise<OauthRegisteredClient | null> {
    const row = await db._query.oauthClients.findFirst({ where: eq(oauthClients.clientId, clientId) })
    return row ? mapClient(row) : null
  },

  async createAuthRequest(input: {
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
  }): Promise<OauthAuthRequest> {
    const [inserted] = await db
      .insert(oauthAuthRequests)
      .values({
        id: input.id,
        clientId: input.clientId,
        redirectUri: input.redirectUri,
        state: input.state,
        scope: input.scope,
        codeChallenge: input.codeChallenge,
        csrfToken: input.csrfToken,
        deviceId: input.deviceId,
        date: toDate(input.nowMs),
        expiresAt: toDate(input.expiresAtMs),
      })
      .returning()

    if (!inserted) {
      throw new Error("failed to create oauth auth request")
    }

    return mapAuthRequest(inserted)
  },

  async getAuthRequest(id: string, nowMs: number): Promise<OauthAuthRequest | null> {
    const row = await db._query.oauthAuthRequests.findFirst({
      where: and(eq(oauthAuthRequests.id, id), gt(oauthAuthRequests.expiresAt, toDate(nowMs))),
    })
    return row ? mapAuthRequest(row) : null
  },

  async setAuthRequestEmail(id: string, email: string, challengeToken: string): Promise<void> {
    await db
      .update(oauthAuthRequests)
      .set({ email, challengeToken })
      .where(eq(oauthAuthRequests.id, id))
  },

  async setAuthRequestInlineSession(input: {
    id: string
    inlineUserId: number
    inlineTokenEncrypted: Buffer
  }): Promise<void> {
    await db
      .update(oauthAuthRequests)
      .set({ inlineUserId: input.inlineUserId, inlineTokenEncrypted: input.inlineTokenEncrypted })
      .where(eq(oauthAuthRequests.id, input.id))
  },

  async deleteAuthRequest(id: string): Promise<void> {
    await db.delete(oauthAuthRequests).where(eq(oauthAuthRequests.id, id))
  },

  async createGrant(input: {
    id: string
    clientId: string
    inlineUserId: number
    scope: string
    spaceIds: bigint[]
    allowDms: boolean
    allowHomeThreads: boolean
    inlineTokenEncrypted: Buffer
    nowMs: number
  }): Promise<OauthGrant> {
    const [inserted] = await db
      .insert(oauthGrants)
      .values({
        id: input.id,
        clientId: input.clientId,
        inlineUserId: input.inlineUserId,
        scope: input.scope,
        spaceIdsJson: input.spaceIds.map((spaceId) => Number(spaceId)),
        allowDms: input.allowDms,
        allowHomeThreads: input.allowHomeThreads,
        inlineTokenEncrypted: input.inlineTokenEncrypted,
        date: toDate(input.nowMs),
      })
      .returning()

    if (!inserted) {
      throw new Error("failed to create oauth grant")
    }

    return mapGrant(inserted)
  },

  async getGrant(grantId: string): Promise<OauthGrant | null> {
    const row = await db._query.oauthGrants.findFirst({ where: eq(oauthGrants.id, grantId) })
    return row ? mapGrant(row) : null
  },

  async revokeGrant(grantId: string, nowMs: number): Promise<void> {
    await db
      .update(oauthGrants)
      .set({ revokedAt: toDate(nowMs) })
      .where(and(eq(oauthGrants.id, grantId), isNull(oauthGrants.revokedAt)))
  },

  async createAuthCode(input: {
    code: string
    grantId: string
    clientId: string
    redirectUri: string
    codeChallenge: string
    nowMs: number
    expiresAtMs: number
  }): Promise<OauthAuthCode> {
    const [inserted] = await db
      .insert(oauthAuthCodes)
      .values({
        code: input.code,
        grantId: input.grantId,
        clientId: input.clientId,
        redirectUri: input.redirectUri,
        codeChallenge: input.codeChallenge,
        date: toDate(input.nowMs),
        expiresAt: toDate(input.expiresAtMs),
      })
      .returning()

    if (!inserted) {
      throw new Error("failed to create oauth authorization code")
    }

    return mapAuthCode(inserted)
  },

  async getAuthCode(code: string, nowMs: number): Promise<OauthAuthCode | null> {
    const row = await db._query.oauthAuthCodes.findFirst({
      where: and(eq(oauthAuthCodes.code, code), gt(oauthAuthCodes.expiresAt, toDate(nowMs))),
    })
    return row ? mapAuthCode(row) : null
  },

  async markAuthCodeUsed(code: string, nowMs: number): Promise<void> {
    await db
      .update(oauthAuthCodes)
      .set({ usedAt: toDate(nowMs) })
      .where(eq(oauthAuthCodes.code, code))
  },

  async createAccessToken(input: {
    tokenHash: string
    grantId: string
    nowMs: number
    expiresAtMs: number
  }): Promise<void> {
    await db.insert(oauthAccessTokens).values({
      tokenHash: input.tokenHash,
      grantId: input.grantId,
      date: toDate(input.nowMs),
      expiresAt: toDate(input.expiresAtMs),
    })
  },

  async getAccessToken(tokenHash: string, nowMs: number): Promise<OauthAccessToken | null> {
    const row = await db._query.oauthAccessTokens.findFirst({
      where: and(
        eq(oauthAccessTokens.tokenHash, tokenHash),
        isNull(oauthAccessTokens.revokedAt),
        gt(oauthAccessTokens.expiresAt, toDate(nowMs)),
      ),
    })
    return row ? mapAccessToken(row) : null
  },

  async createRefreshToken(input: {
    tokenHash: string
    grantId: string
    nowMs: number
    expiresAtMs: number
  }): Promise<void> {
    await db.insert(oauthRefreshTokens).values({
      tokenHash: input.tokenHash,
      grantId: input.grantId,
      date: toDate(input.nowMs),
      expiresAt: toDate(input.expiresAtMs),
    })
  },

  async getRefreshToken(tokenHash: string, nowMs: number): Promise<OauthRefreshToken | null> {
    const row = await db._query.oauthRefreshTokens.findFirst({
      where: and(
        eq(oauthRefreshTokens.tokenHash, tokenHash),
        isNull(oauthRefreshTokens.revokedAt),
        gt(oauthRefreshTokens.expiresAt, toDate(nowMs)),
      ),
    })
    return row ? mapRefreshToken(row) : null
  },

  async revokeRefreshToken(tokenHash: string, nowMs: number, replacedByHash: string | null): Promise<void> {
    await db
      .update(oauthRefreshTokens)
      .set({ revokedAt: toDate(nowMs), replacedByHash })
      .where(eq(oauthRefreshTokens.tokenHash, tokenHash))
  },

  async revokeRefreshTokensByGrant(grantId: string, nowMs: number): Promise<void> {
    await db
      .update(oauthRefreshTokens)
      .set({ revokedAt: toDate(nowMs), replacedByHash: null })
      .where(and(eq(oauthRefreshTokens.grantId, grantId), isNull(oauthRefreshTokens.revokedAt)))
  },

  async revokeAccessTokensByGrant(grantId: string, nowMs: number): Promise<void> {
    await db
      .update(oauthAccessTokens)
      .set({ revokedAt: toDate(nowMs) })
      .where(and(eq(oauthAccessTokens.grantId, grantId), isNull(oauthAccessTokens.revokedAt)))
  },

  async findGrantIdByTokenHash(tokenHash: string): Promise<string | null> {
    const refresh = await db._query.oauthRefreshTokens.findFirst({ where: eq(oauthRefreshTokens.tokenHash, tokenHash) })
    if (refresh) return refresh.grantId

    const access = await db._query.oauthAccessTokens.findFirst({ where: eq(oauthAccessTokens.tokenHash, tokenHash) })
    if (access) return access.grantId

    return null
  },

  async getGrantByActiveAccessTokenHash(tokenHash: string, nowMs: number): Promise<{ grant: OauthGrant; accessToken: OauthAccessToken } | null> {
    const row = (
      await db
        .select({ grant: oauthGrants, accessToken: oauthAccessTokens })
        .from(oauthAccessTokens)
        .innerJoin(oauthGrants, eq(oauthAccessTokens.grantId, oauthGrants.id))
        .where(
          and(
            eq(oauthAccessTokens.tokenHash, tokenHash),
            isNull(oauthAccessTokens.revokedAt),
            gt(oauthAccessTokens.expiresAt, toDate(nowMs)),
            isNull(oauthGrants.revokedAt),
          ),
        )
        .limit(1)
    )[0]

    if (!row) return null
    return {
      grant: mapGrant(row.grant),
      accessToken: mapAccessToken(row.accessToken),
    }
  },

  async getGrantForRefreshTokenHash(tokenHash: string, nowMs: number): Promise<{ grant: OauthGrant; refreshToken: OauthRefreshToken } | null> {
    const row = (
      await db
        .select({ grant: oauthGrants, refreshToken: oauthRefreshTokens })
        .from(oauthRefreshTokens)
        .innerJoin(oauthGrants, eq(oauthRefreshTokens.grantId, oauthGrants.id))
        .where(
          and(
            eq(oauthRefreshTokens.tokenHash, tokenHash),
            isNull(oauthRefreshTokens.revokedAt),
            gt(oauthRefreshTokens.expiresAt, toDate(nowMs)),
            isNull(oauthGrants.revokedAt),
          ),
        )
        .limit(1)
    )[0]

    if (!row) return null
    return {
      grant: mapGrant(row.grant),
      refreshToken: mapRefreshToken(row.refreshToken),
    }
  },

  async revokeGrantByAnyTokenHash(tokenHash: string, nowMs: number): Promise<void> {
    const grantId = await this.findGrantIdByTokenHash(tokenHash)
    if (!grantId) return

    await Promise.all([
      this.revokeGrant(grantId, nowMs),
      this.revokeRefreshTokensByGrant(grantId, nowMs),
      this.revokeAccessTokensByGrant(grantId, nowMs),
    ])
  },

  async pruneAuthDataForUser(userId: number, nowMs: number): Promise<void> {
    await db
      .delete(oauthAuthRequests)
      .where(
        and(
          eq(oauthAuthRequests.inlineUserId, userId),
          or(isNull(oauthAuthRequests.expiresAt), sql`${oauthAuthRequests.expiresAt} <= ${toDate(nowMs)}`),
        ),
      )
  },
}
