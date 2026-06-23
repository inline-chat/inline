import {
  InputScope,
  OAuthConnectionStatus,
  type OAuthConnectionInfo,
} from "@inline-chat/protocol/core"
import { CHATGPT_CONNECTION_PROVIDER } from "@inline-chat/agent-chatgpt"
import { and, desc, eq, isNotNull } from "drizzle-orm"
import { db } from "@in/server/db"
import { oauthConnections, type DbOauthConnection } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"

export type ConnectionScope =
  | {
      readonly type: "user"
      readonly userId: number
    }
  | {
      readonly type: "space"
      readonly spaceId: number
    }

export type CodexCredential = {
  readonly accessToken: string
  readonly refreshToken: string
  readonly expiresAt?: number
  readonly tokenType?: string
  readonly scopes?: readonly string[]
}

export type ConnectionIdentity = {
  readonly accountId?: string
  readonly email?: string
  readonly profileName?: string
  readonly chatgptPlanType?: string
}

export type StoredCodexConnection = {
  readonly row: DbOauthConnection
  readonly credential: CodexCredential
  readonly identity?: ConnectionIdentity
}

const revokedCredential: CodexCredential = {
  accessToken: "revoked",
  refreshToken: "revoked",
}

export async function listCurrentUserConnections(userId: number): Promise<OAuthConnectionInfo[]> {
  const rows = await db
    .select()
    .from(oauthConnections)
    .where(
      and(
        eq(oauthConnections.scopeType, "user"),
        eq(oauthConnections.userId, userId),
        isNotNull(oauthConnections.userId),
      ),
    )
    .orderBy(desc(oauthConnections.updatedAt), desc(oauthConnections.id))

  return rows.filter((row) => row.status !== "revoked").map(encodeConnectionInfo)
}

export async function findActiveUserCodexConnection(userId: number): Promise<StoredCodexConnection | undefined> {
  const [row] = await db
    .select()
    .from(oauthConnections)
    .where(
      and(
        eq(oauthConnections.provider, CHATGPT_CONNECTION_PROVIDER),
        eq(oauthConnections.scopeType, "user"),
        eq(oauthConnections.userId, userId),
        eq(oauthConnections.status, "active"),
      ),
    )
    .orderBy(desc(oauthConnections.updatedAt), desc(oauthConnections.id))
    .limit(1)

  return row ? decodeStoredConnection(row) : undefined
}

export async function getOwnedConnection(input: {
  readonly connectionId: number
  readonly userId: number
}): Promise<StoredCodexConnection | undefined> {
  const [row] = await db
    .select()
    .from(oauthConnections)
    .where(and(eq(oauthConnections.id, input.connectionId), eq(oauthConnections.userId, input.userId)))
    .limit(1)

  return row ? decodeStoredConnection(row) : undefined
}

export async function saveCodexConnection(input: {
  readonly scope: ConnectionScope
  readonly connectedByUserId: number
  readonly credential: CodexCredential
  readonly identity?: ConnectionIdentity
}): Promise<OAuthConnectionInfo> {
  const now = new Date()

  const row = await db.transaction(async (tx) => {
    if (input.scope.type === "user") {
      await tx
        .update(oauthConnections)
        .set({
          status: "revoked",
          revokedAt: now,
          updatedAt: now,
        })
        .where(
          and(
            eq(oauthConnections.provider, CHATGPT_CONNECTION_PROVIDER),
            eq(oauthConnections.scopeType, "user"),
            eq(oauthConnections.userId, input.scope.userId),
            eq(oauthConnections.status, "active"),
          ),
        )

      const [created] = await tx
        .insert(oauthConnections)
        .values({
          provider: CHATGPT_CONNECTION_PROVIDER,
          scopeType: "user",
          userId: input.scope.userId,
          connectedByUserId: input.connectedByUserId,
          credentialCiphertext: encryptJson(input.credential),
          identityCiphertext: input.identity ? encryptJson(input.identity) : null,
          status: "active",
          expiresAt: input.credential.expiresAt ? new Date(input.credential.expiresAt) : null,
          updatedAt: now,
        })
        .returning()

      return created
    }

    await tx
      .update(oauthConnections)
      .set({
        status: "revoked",
        revokedAt: now,
        updatedAt: now,
      })
      .where(
        and(
          eq(oauthConnections.provider, CHATGPT_CONNECTION_PROVIDER),
          eq(oauthConnections.scopeType, "space"),
          eq(oauthConnections.spaceId, input.scope.spaceId),
          eq(oauthConnections.status, "active"),
        ),
      )

    const [created] = await tx
      .insert(oauthConnections)
      .values({
        provider: CHATGPT_CONNECTION_PROVIDER,
        scopeType: "space",
        spaceId: input.scope.spaceId,
        connectedByUserId: input.connectedByUserId,
        credentialCiphertext: encryptJson(input.credential),
        identityCiphertext: input.identity ? encryptJson(input.identity) : null,
        status: "active",
        expiresAt: input.credential.expiresAt ? new Date(input.credential.expiresAt) : null,
        updatedAt: now,
      })
      .returning()

    return created
  })

  if (!row) {
    throw new Error("Failed to save ChatGPT connection")
  }

  return encodeConnectionInfo(row)
}

export async function updateConnectionCredential(input: {
  readonly connectionId: number
  readonly credential: CodexCredential
  readonly identity?: ConnectionIdentity
}): Promise<void> {
  const now = new Date()
  await db
    .update(oauthConnections)
    .set({
      credentialCiphertext: encryptJson(input.credential),
      identityCiphertext: input.identity ? encryptJson(input.identity) : undefined,
      expiresAt: input.credential.expiresAt ? new Date(input.credential.expiresAt) : null,
      lastRefreshAt: now,
      status: "active",
      errorAt: null,
      errorCode: null,
      errorMessage: null,
      updatedAt: now,
    })
    .where(eq(oauthConnections.id, input.connectionId))
}

export async function markConnectionUsed(connectionId: number): Promise<void> {
  const now = new Date()
  await db
    .update(oauthConnections)
    .set({
      lastUsedAt: now,
      updatedAt: now,
    })
    .where(eq(oauthConnections.id, connectionId))
}

export async function markConnectionError(input: {
  readonly connectionId: number
  readonly errorCode: string
  readonly errorMessage?: string
}): Promise<void> {
  const now = new Date()
  await db
    .update(oauthConnections)
    .set({
      status: "error",
      errorCode: input.errorCode,
      errorMessage: input.errorMessage?.slice(0, 1000),
      errorAt: now,
      updatedAt: now,
    })
    .where(eq(oauthConnections.id, input.connectionId))
}

export async function disconnectOwnedConnection(input: {
  readonly connectionId: number
  readonly userId: number
}): Promise<boolean> {
  const now = new Date()
  const rows = await db
    .update(oauthConnections)
    .set({
      status: "revoked",
      credentialCiphertext: encryptJson(revokedCredential),
      identityCiphertext: null,
      configCiphertext: null,
      revokedAt: now,
      updatedAt: now,
    })
    .where(and(eq(oauthConnections.id, input.connectionId), eq(oauthConnections.userId, input.userId)))
    .returning({ id: oauthConnections.id })

  return rows.length > 0
}

export function encodeConnectionInfo(row: DbOauthConnection): OAuthConnectionInfo {
  const identity = row.identityCiphertext ? decryptJson<ConnectionIdentity>(row.identityCiphertext) : undefined
  const scope = encodeInputScope(row)

  return {
    id: BigInt(row.id),
    provider: row.provider,
    scope,
    status: encodeStatus(row.status),
    displayName: identity?.profileName ?? identity?.email,
    email: identity?.email,
    plan: identity?.chatgptPlanType,
    expiresAt: row.expiresAt ? BigInt(Math.floor(row.expiresAt.getTime() / 1000)) : undefined,
    lastUsedAt: row.lastUsedAt ? BigInt(Math.floor(row.lastUsedAt.getTime() / 1000)) : undefined,
    errorAt: row.errorAt ? BigInt(Math.floor(row.errorAt.getTime() / 1000)) : undefined,
    errorCode: row.errorCode ?? undefined,
  }
}

export function decodeStoredConnection(row: DbOauthConnection): StoredCodexConnection {
  return {
    row,
    credential: decryptJson<CodexCredential>(row.credentialCiphertext),
    identity: row.identityCiphertext ? decryptJson<ConnectionIdentity>(row.identityCiphertext) : undefined,
  }
}

export function inputScopeForCurrentUser(userId: number): InputScope {
  return { type: { oneofKind: "user", user: { userId: BigInt(userId) } } }
}

export function decodeInputScope(scope: InputScope | undefined, currentUserId: number): ConnectionScope | undefined {
  if (!scope || scope.type.oneofKind === undefined) {
    return { type: "user", userId: currentUserId }
  }

  switch (scope.type.oneofKind) {
    case "user": {
      const userId = Number(scope.type.user.userId)
      return Number.isSafeInteger(userId) && userId > 0 ? { type: "user", userId } : undefined
    }
    case "space": {
      const spaceId = Number(scope.type.space.spaceId)
      return Number.isSafeInteger(spaceId) && spaceId > 0 ? { type: "space", spaceId } : undefined
    }
  }
}

function encodeInputScope(row: DbOauthConnection): InputScope | undefined {
  if (row.scopeType === "user" && row.userId != null) {
    return { type: { oneofKind: "user", user: { userId: BigInt(row.userId) } } }
  }

  if (row.scopeType === "space" && row.spaceId != null) {
    return { type: { oneofKind: "space", space: { spaceId: BigInt(row.spaceId) } } }
  }

  return undefined
}

function encodeStatus(status: string): OAuthConnectionStatus {
  switch (status) {
    case "active":
      return OAuthConnectionStatus.OAUTH_CONNECTION_ACTIVE
    case "error":
      return OAuthConnectionStatus.OAUTH_CONNECTION_ERROR
    case "revoked":
      return OAuthConnectionStatus.OAUTH_CONNECTION_REVOKED
    default:
      return OAuthConnectionStatus.OAUTH_CONNECTION_STATUS_UNSPECIFIED
  }
}

function encryptJson(value: unknown): Buffer {
  return Encryption2.encrypt(Buffer.from(JSON.stringify(value), "utf8"))
}

function decryptJson<T>(ciphertext: Buffer): T {
  return JSON.parse(Encryption2.decryptToString(Buffer.from(ciphertext))) as T
}
