import { db } from "@in/server/db"
import { integrations, spaces } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { usableOAuthAccessToken } from "./oauthTokenLifecycle"
import { and, desc, eq, isNull } from "drizzle-orm"

const log = new Log("modules.integrations.auth")

export type IntegrationAuthOwner =
  | { readonly type: "user"; readonly userId: number }
  | { readonly type: "space"; readonly spaceId: number }

export interface IntegrationAuthToken {
  readonly provider: string
  readonly accessToken: string
  readonly integrationId: number
  readonly owner: IntegrationAuthOwner
}

export interface IntegrationAuthInput {
  readonly provider: string
  readonly currentUserId: number
  readonly spaceId: number | null
}

export interface IntegrationAuthPolicy {
  /** Ordered scopes to try for a chat that belongs to a space. */
  readonly scopeOrderInSpace: readonly IntegrationAuthOwner["type"][]
}

export interface IntegrationAuthRow {
  readonly id: number
  readonly provider: string
  readonly date: Date
  readonly userId: number | null
  readonly spaceId: number | null
  readonly accessTokenEncrypted: Buffer | null
  readonly accessTokenIv: Buffer | null
  readonly accessTokenTag: Buffer | null
}

export interface IntegrationAuthResolverDeps {
  readonly findSpaceIntegration: (
    provider: string,
    spaceId: number,
  ) => Promise<IntegrationAuthRow | null>
  readonly findUserIntegration: (
    provider: string,
    userId: number,
  ) => Promise<IntegrationAuthRow | null>
  readonly decryptToken: (row: IntegrationAuthRow) => unknown | Promise<unknown>
}

/** Restricted consumers can explicitly opt into space-only credentials. */
export const spaceOnlyIntegrationAuthPolicy: IntegrationAuthPolicy = {
  scopeOrderInSpace: ["space"],
}

/** External search currently prefers a personal connection, then the space connection. */
export const userThenSpaceIntegrationAuthPolicy: IntegrationAuthPolicy = {
  scopeOrderInSpace: ["user", "space"],
}

export async function resolveIntegrationAuth(
  input: IntegrationAuthInput,
  policy: IntegrationAuthPolicy = spaceOnlyIntegrationAuthPolicy,
): Promise<IntegrationAuthToken | null> {
  const [connection] = await resolveIntegrationAuthCandidatesWithDeps(
    input,
    defaultDeps,
    policy,
  )
  return connection ?? null
}

export async function resolveIntegrationAuthWithDeps(
  input: IntegrationAuthInput,
  deps: IntegrationAuthResolverDeps,
  policy: IntegrationAuthPolicy = spaceOnlyIntegrationAuthPolicy,
): Promise<IntegrationAuthToken | null> {
  const [connection] = await resolveIntegrationAuthCandidatesWithDeps(
    input,
    deps,
    policy,
  )
  return connection ?? null
}

/** Returns every usable connection in policy order for provider-level fallback. */
export async function resolveIntegrationAuthCandidates(
  input: IntegrationAuthInput,
  policy: IntegrationAuthPolicy = spaceOnlyIntegrationAuthPolicy,
): Promise<IntegrationAuthToken[]> {
  return resolveIntegrationAuthCandidatesWithDeps(input, defaultDeps, policy)
}

export async function resolveIntegrationAuthCandidatesWithDeps(
  input: IntegrationAuthInput,
  deps: IntegrationAuthResolverDeps,
  policy: IntegrationAuthPolicy = spaceOnlyIntegrationAuthPolicy,
): Promise<IntegrationAuthToken[]> {
  const scopes = input.spaceId === null
    ? (["user"] as const)
    : policy.scopeOrderInSpace
  const connections: IntegrationAuthToken[] = []

  for (const scope of new Set(scopes)) {
    const owner = ownerForScope(scope, input)
    if (!owner) continue

    const row = owner.type === "user"
      ? await deps.findUserIntegration(input.provider, input.currentUserId)
      : await deps.findSpaceIntegration(input.provider, owner.spaceId)
    const accessToken = await readIntegrationAccessToken(
      row,
      deps,
      owner,
      input.provider,
    )
    if (row && accessToken) {
      connections.push({
        provider: row.provider,
        accessToken,
        integrationId: row.id,
        owner,
      })
    }
  }

  return connections
}

export function accessTokenFromPayload(payload: unknown): string | null {
  const direct = stringField(payload, "access_token")
  if (direct) return direct

  const data = recordField(payload, "data")
  return stringField(data, "access_token")
}

function ownerForScope(
  scope: IntegrationAuthOwner["type"],
  input: IntegrationAuthInput,
): IntegrationAuthOwner | null {
  if (scope === "user") {
    return { type: "user", userId: input.currentUserId }
  }
  return input.spaceId === null
    ? null
    : { type: "space", spaceId: input.spaceId }
}

async function readIntegrationAccessToken(
  row: IntegrationAuthRow | null,
  deps: IntegrationAuthResolverDeps,
  owner: IntegrationAuthOwner,
  expectedProvider: string,
): Promise<string | null> {
  if (!row) return null

  const belongsToOwner = owner.type === "user"
    ? row.userId === owner.userId && row.spaceId === null
    : row.spaceId === owner.spaceId
  if (row.provider !== expectedProvider || !belongsToOwner) {
    log.warn("Integration lookup returned a mismatched owner or provider", {
      provider: expectedProvider,
      integrationId: row.id,
      ownerType: owner.type,
    })
    return null
  }

  if (
    !row.accessTokenEncrypted ||
    !row.accessTokenIv ||
    !row.accessTokenTag
  ) {
    log.warn("Integration is missing encrypted token data", {
      provider: row.provider,
      integrationId: row.id,
      ownerType: owner.type,
    })
    return null
  }

  let payload: unknown
  try {
    payload = await deps.decryptToken(row)
  } catch (cause) {
    log.warn("Failed to read integration token payload", {
      provider: row.provider,
      integrationId: row.id,
      ownerType: owner.type,
      causeName: cause instanceof Error ? cause.name : "UnknownError",
    })
    return null
  }

  const accessToken = accessTokenFromPayload(payload)
  if (!accessToken) {
    log.warn("Integration token payload is missing access token", {
      provider: row.provider,
      integrationId: row.id,
      ownerType: owner.type,
    })
  }
  return accessToken
}

const selectedIntegrationColumns = {
  id: integrations.id,
  provider: integrations.provider,
  date: integrations.date,
  userId: integrations.userId,
  spaceId: integrations.spaceId,
  accessTokenEncrypted: integrations.accessTokenEncrypted,
  accessTokenIv: integrations.accessTokenIv,
  accessTokenTag: integrations.accessTokenTag,
}

const defaultDeps: IntegrationAuthResolverDeps = {
  async findSpaceIntegration(provider, spaceId) {
    const [row] = await db
      .select(selectedIntegrationColumns)
      .from(integrations)
      .innerJoin(spaces, eq(integrations.spaceId, spaces.id))
      .where(and(
        eq(integrations.provider, provider),
        eq(integrations.spaceId, spaceId),
        eq(spaces.isPublic, false),
        isNull(spaces.deleted),
      ))
      .limit(1)
    return row ?? null
  },

  async findUserIntegration(provider, userId) {
    const [row] = await db
      .select(selectedIntegrationColumns)
      .from(integrations)
      .where(and(
        eq(integrations.provider, provider),
        eq(integrations.userId, userId),
        isNull(integrations.spaceId),
      ))
      .orderBy(desc(integrations.date), desc(integrations.id))
      .limit(1)
    return row ?? null
  },

  async decryptToken(row) {
    const accessToken = await usableOAuthAccessToken(row)
    return accessToken ? { access_token: accessToken } : null
  },
}

function recordField(value: unknown, key: string): Record<string, unknown> | null {
  const record = asRecord(value)
  return asRecord(record?.[key])
}

function stringField(value: unknown, key: string): string | null {
  const record = asRecord(value)
  const field = record?.[key]
  return typeof field === "string" && field.length > 0 ? field : null
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}
