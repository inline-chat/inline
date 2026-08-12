import * as arctic from "arctic"
import {
  ConnectorProvider,
  type ConnectorConnection,
  type DisconnectConnectorInput,
  type InputScope,
  type DisconnectConnectorResult,
  type ListConnectorsResult,
  type PrepareConnectorOAuthInput,
  type PrepareConnectorOAuthResult,
  type Scope,
} from "@inline-chat/protocol/core"
import { and, desc, eq, inArray, isNull, or } from "drizzle-orm"
import { db } from "@in/server/db"
import { files, integrations, members, spaces, users } from "@in/server/db/schema"
import { decryptLinearTokens } from "@in/server/libs/helpers"
import { getLinearAuthUrl, linearOauth, revokeLinearToken } from "@in/server/libs/linear"
import { getNotionAuthUrl, notionOauth, revokeNotionToken } from "@in/server/libs/notion"
import { resolveConnectorCallbackScheme } from "@in/server/modules/integrations/connectorCallbackScheme"
import { storeConnectorOAuthState, type ConnectorOAuthProvider } from "@in/server/modules/integrations/connectorOAuthState"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeSpace } from "@in/server/realtime/encoders/encodeSpace"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import type { HandlerContext } from "@in/server/realtime/types"
import { InlineError } from "@in/server/types/errors"
import { Authorize } from "@in/server/utils/authorize"
import { Log } from "@in/server/utils/log"

const log = new Log("connectors")

type ConnectorScopeIdentity =
  | { type: "user"; userId: number; spaceId: null }
  | { type: "space"; userId: number; spaceId: number }

interface DisconnectConnectorDependencies {
  readonly revokeConnection: typeof revokeConnectorConnection
}

const providerInfos = () => [
  {
    provider: ConnectorProvider.NOTION,
    available: notionOauth !== undefined,
    supportsUserScope: true,
    supportsSpaceScope: true,
  },
  {
    provider: ConnectorProvider.LINEAR,
    available: linearOauth !== undefined,
    supportsUserScope: false,
    supportsSpaceScope: true,
  },
  {
    provider: ConnectorProvider.GITHUB,
    available: false,
    supportsUserScope: false,
    supportsSpaceScope: false,
  },
]

export async function listConnectors(
  context: HandlerContext,
): Promise<ListConnectorsResult> {
  rejectBots(context)

  const [currentUser, membershipRows] = await Promise.all([
    db._query.users.findFirst({ where: eq(users.id, context.userId) }),
    db
      .select({
        space: spaces,
        role: members.role,
      })
      .from(members)
      .innerJoin(spaces, eq(members.spaceId, spaces.id))
      .where(and(
        eq(members.userId, context.userId),
        isNull(spaces.deleted),
      ))
      .orderBy(spaces.name),
  ])

  if (!currentUser) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  const personalScope = scopeForUser(currentUser)
  const resolvedSpaceScopes = membershipRows.map((row) => ({
    ...row,
    scope: scopeForSpace(row.space, context.userId),
  }))
  const spaceScopes = new Map(
    resolvedSpaceScopes.filter((row) =>
      !row.space.isPublic || row.role === "owner" || row.role === "admin"
    ).map((row) => [
      row.space.id,
      row.scope,
    ] as const),
  )
  const spaceIds = [...spaceScopes.keys()]
  const visibleConnection = spaceIds.length > 0
    ? or(
        and(eq(integrations.userId, context.userId), isNull(integrations.spaceId)),
        inArray(integrations.spaceId, spaceIds),
      )
    : and(eq(integrations.userId, context.userId), isNull(integrations.spaceId))

  const rows = await db
    .select({
      integration: integrations,
      connectedBy: users,
      photoFile: files,
    })
    .from(integrations)
    .leftJoin(users, eq(integrations.userId, users.id))
    .leftJoin(files, eq(users.photoFileId, files.id))
    .where(visibleConnection)
    .orderBy(desc(integrations.date), desc(integrations.id))

  const seen = new Set<string>()
  const connections: ConnectorConnection[] = []
  for (const row of rows) {
    const provider = encodeProvider(row.integration.provider)
    if (provider === null) continue
    if (!hasStoredCredentials(row.integration)) continue

    const scope = row.integration.spaceId === null
      ? personalScope
      : spaceScopes.get(row.integration.spaceId)
    if (!scope) continue
    const key = row.integration.spaceId === null
      ? `user:${context.userId}:${provider}`
      : `space:${row.integration.spaceId}:${provider}`
    if (seen.has(key)) continue
    seen.add(key)

    connections.push({
      provider,
      scope,
      connectedAt: BigInt(Math.floor(row.integration.date.getTime() / 1_000)),
      connectedBy: row.connectedBy
        ? encodeUser({
            user: row.connectedBy,
            photoFile: row.photoFile ?? undefined,
            min: true,
          })
        : undefined,
      needsConfiguration: row.integration.spaceId !== null && (
        (provider === ConnectorProvider.LINEAR && !row.integration.linearTeamId)
        || (provider === ConnectorProvider.NOTION && !row.integration.notionDatabaseId)
      ),
    })
  }

  return {
    providers: providerInfos(),
    scopes: [
      {
        scope: personalScope,
        canManage: true,
        allowsConnections: true,
      },
      ...resolvedSpaceScopes.map((row) => ({
        scope: row.scope,
        canManage: row.role === "owner" || row.role === "admin",
        allowsConnections: !row.space.isPublic,
      })),
    ],
    connections,
  }
}

export async function prepareConnectorOAuth(
  input: PrepareConnectorOAuthInput,
  context: HandlerContext,
): Promise<PrepareConnectorOAuthResult> {
  rejectBots(context)
  const provider = decodeSupportedProvider(input.provider)
  const scope = await authorizeScope(input.scope, context)
  if (!providerSupportsScope(provider, scope.type) || !isProviderAvailable(provider)) {
    throw RealtimeRpcError.BadRequest()
  }
  const callbackScheme = resolveConnectorCallbackScheme(input.callbackScheme)
  if (!callbackScheme) throw RealtimeRpcError.BadRequest()
  const state = arctic.generateState()
  const auth = provider === "linear"
    ? getLinearAuthUrl(state)
    : getNotionAuthUrl(state)
  const authorizationUrl = auth.url?.toString()

  if (!authorizationUrl) {
    throw RealtimeRpcError.BadRequest()
  }

  await storeConnectorOAuthState({
    state,
    provider,
    callbackScheme,
    userId: scope.userId,
    spaceId: scope.spaceId,
  })

  return { authorizationUrl }
}

export async function disconnectConnector(
  input: DisconnectConnectorInput,
  context: HandlerContext,
  dependencies: DisconnectConnectorDependencies = {
    revokeConnection: revokeConnectorConnection,
  },
): Promise<DisconnectConnectorResult> {
  rejectBots(context)
  const provider = decodeSupportedProvider(input.provider)
  const scope = await authorizeScope(input.scope, context, { allowPublicSpace: true })
  await disconnectConnectorCredentials(provider, scope, dependencies)

  return {}
}

export async function disconnectSpaceConnectorCredentials(
  provider: ConnectorOAuthProvider,
  input: { userId: number; spaceId: number },
): Promise<void> {
  await disconnectConnectorCredentials(provider, {
    type: "space",
    userId: input.userId,
    spaceId: input.spaceId,
  }, {
    revokeConnection: revokeConnectorConnection,
  })
}

async function disconnectConnectorCredentials(
  provider: ConnectorOAuthProvider,
  scope: ConnectorScopeIdentity,
  dependencies: DisconnectConnectorDependencies,
): Promise<void> {
  const scopeClause = scope.spaceId === null
    ? and(eq(integrations.userId, scope.userId), isNull(integrations.spaceId))
    : eq(integrations.spaceId, scope.spaceId)

  const outcome = await db.transaction(async (tx) => {
    if (scope.spaceId === null) {
      await tx
        .select({ id: users.id })
        .from(users)
        .where(eq(users.id, scope.userId))
        .for("update")
        .limit(1)
    } else {
      await tx
        .select({ id: spaces.id })
        .from(spaces)
        .where(eq(spaces.id, scope.spaceId))
        .for("update")
        .limit(1)
    }

    const connections = await tx
      .select()
      .from(integrations)
      .where(and(scopeClause, eq(integrations.provider, provider)))
      .orderBy(desc(integrations.date), desc(integrations.id))

    const attempts = await Promise.all(connections.map(async (connection) => {
      try {
        const result = await dependencies.revokeConnection(provider, connection)
        return {
          connection,
          ok: result.ok,
          status: result.status ?? "UnknownError",
        }
      } catch (error) {
        return {
          connection,
          ok: false,
          status: error instanceof Error ? error.name : "UnknownError",
        }
      }
    }))

    const revokedConnections = attempts
      .filter((attempt) => attempt.ok)
      .map((attempt) => attempt.connection)
    const unchangedRevokedConnections = revokedConnections.map((connection) => and(
      eq(integrations.id, connection.id),
      connection.accessTokenEncrypted === null
        ? isNull(integrations.accessTokenEncrypted)
        : eq(integrations.accessTokenEncrypted, connection.accessTokenEncrypted),
      connection.accessTokenIv === null
        ? isNull(integrations.accessTokenIv)
        : eq(integrations.accessTokenIv, connection.accessTokenIv),
      connection.accessTokenTag === null
        ? isNull(integrations.accessTokenTag)
        : eq(integrations.accessTokenTag, connection.accessTokenTag),
    ))
    if (unchangedRevokedConnections.length > 0) {
      await tx
        .delete(integrations)
        .where(or(...unchangedRevokedConnections))
    }

    return {
      attemptedCount: attempts.length,
      failedAttempts: attempts.filter((attempt) => !attempt.ok),
    }
  })

  const { failedAttempts } = outcome
  if (failedAttempts.length > 0) {
    log.warn("Provider token revocation failed during connector disconnect", {
      provider,
      scopeType: scope.type,
      failedCount: failedAttempts.length,
      attemptedCount: outcome.attemptedCount,
      statuses: failedAttempts.map((attempt) => attempt.status),
    })
    throw RealtimeRpcError.InternalError()
  }
}

async function authorizeScope(
  scope: InputScope | undefined,
  context: HandlerContext,
  options: { allowPublicSpace?: boolean } = {},
): Promise<ConnectorScopeIdentity> {
  if (!scope) throw RealtimeRpcError.BadRequest()

  if (scope.type.oneofKind === "user") {
    const userId = safeId(scope.type.user.userId)
    if (userId !== context.userId) throw RealtimeRpcError.UserIdInvalid()
    return { type: "user", userId, spaceId: null }
  }

  if (scope.type.oneofKind === "space") {
    const spaceId = safeId(scope.type.space.spaceId)
    try {
      await Authorize.spaceAdmin(spaceId, context.userId)
    } catch (error) {
      if (error instanceof InlineError && error.type === "SPACE_ADMIN_REQUIRED") {
        throw RealtimeRpcError.SpaceAdminRequired()
      }
      throw error
    }
    if (!options.allowPublicSpace) {
      const [privateSpace] = await db
        .select({ id: spaces.id })
        .from(spaces)
        .where(and(
          eq(spaces.id, spaceId),
          eq(spaces.isPublic, false),
          isNull(spaces.deleted),
        ))
        .limit(1)
      if (!privateSpace) throw RealtimeRpcError.BadRequest()
    }
    return { type: "space", userId: context.userId, spaceId }
  }

  throw RealtimeRpcError.BadRequest()
}

function decodeSupportedProvider(value: ConnectorProvider): ConnectorOAuthProvider {
  if (value === ConnectorProvider.NOTION) return "notion"
  if (value === ConnectorProvider.LINEAR) return "linear"
  throw RealtimeRpcError.BadRequest()
}

function isProviderAvailable(provider: ConnectorOAuthProvider): boolean {
  return provider === "notion" ? notionOauth !== undefined : linearOauth !== undefined
}

function providerSupportsScope(
  provider: ConnectorOAuthProvider,
  scopeType: ConnectorScopeIdentity["type"],
): boolean {
  return provider === "notion" || scopeType === "space"
}

function encodeProvider(value: string): ConnectorProvider | null {
  if (value === "notion") return ConnectorProvider.NOTION
  if (value === "linear") return ConnectorProvider.LINEAR
  if (value === "github") return ConnectorProvider.GITHUB
  return null
}

function hasStoredCredentials(
  integration: typeof integrations.$inferSelect,
): boolean {
  return integration.accessTokenEncrypted !== null &&
    integration.accessTokenIv !== null &&
    integration.accessTokenTag !== null
}

function scopeForUser(user: typeof users.$inferSelect): Scope {
  return {
    type: {
      oneofKind: "user",
      user: {
        user: encodeUser({ user, min: true }),
      },
    },
  }
}

function scopeForSpace(
  space: typeof spaces.$inferSelect,
  currentUserId: number,
): Scope {
  return {
    type: {
      oneofKind: "space",
      space: {
        space: encodeSpace(space, { encodingForUserId: currentUserId }),
      },
    },
  }
}

function safeId(value: bigint): number {
  const id = Number(value)
  if (!Number.isSafeInteger(id) || id <= 0) throw RealtimeRpcError.BadRequest()
  return id
}

function rejectBots(context: HandlerContext): void {
  if (context.isBot) throw RealtimeRpcError.BadRequest()
}

async function revokeLinearConnection(
  connection: typeof integrations.$inferSelect,
): Promise<{ ok: boolean; status?: number }> {
  if (
    !connection.accessTokenEncrypted ||
    !connection.accessTokenIv ||
    !connection.accessTokenTag
  ) return { ok: false }

  const parsed = decryptLinearTokens({
    encrypted: connection.accessTokenEncrypted,
    iv: connection.accessTokenIv,
    authTag: connection.accessTokenTag,
  })
  const accessToken = parsed?.data?.access_token as string | undefined
  const refreshToken = parsed?.data?.refresh_token as string | undefined
  return revokeLinearToken({ accessToken, refreshToken })
}

export async function revokeConnectorConnection(
  provider: ConnectorOAuthProvider,
  connection: typeof integrations.$inferSelect,
): Promise<{ ok: boolean; status?: number }> {
  if (provider === "linear") return revokeLinearConnection(connection)
  if (
    !connection.accessTokenEncrypted ||
    !connection.accessTokenIv ||
    !connection.accessTokenTag
  ) return { ok: false }
  const parsed = decryptLinearTokens({
    encrypted: connection.accessTokenEncrypted,
    iv: connection.accessTokenIv,
    authTag: connection.accessTokenTag,
  })
  const accessToken = parsed?.data?.access_token as string | undefined
  return accessToken ? revokeNotionToken(accessToken) : { ok: false }
}
