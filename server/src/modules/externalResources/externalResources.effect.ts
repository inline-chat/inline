import type { InputPeer } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  resolveIntegrationAuthCandidates,
  userThenSpaceIntegrationAuthPolicy,
  type IntegrationAuthToken,
} from "@in/server/modules/integrations/authResolver"
import {
  InMemoryRateLimiter,
  type RateLimitRule,
} from "@in/server/modules/oauth/rateLimiter"
import { Log } from "@in/server/utils/log"
import {
  Context,
  Data,
  Effect,
  Layer,
} from "effect"
import { ExternalResourceCache } from "./cache"
import { searchNotionResources } from "./notion"

const log = new Log("modules.externalResources")

export type ExternalResourceProviderName = "notion" | "linear" | "github"
export type ExternalResourceKindName =
  | "page"
  | "database"
  | "issue"
  | "pullRequest"
  | "repository"
  | "other"

export interface ExternalResourceRecord {
  readonly id: string
  readonly provider: ExternalResourceProviderName
  readonly kind: ExternalResourceKindName
  readonly title: string
  readonly url: string
  readonly subtitle?: string | undefined
  readonly emoji?: string | undefined
}

export interface ExternalResourceSearchInput {
  readonly peerId: InputPeer
  readonly currentUserId: number
  readonly query: string
  readonly limit?: number | undefined
}

export class ExternalResourceInputError extends Data.TaggedError(
  "ExternalResourceInputError",
)<{ readonly reason: "query" | "limit" }> {}

export class ExternalResourceAccessFailure extends Data.TaggedError(
  "ExternalResourceAccessFailure",
)<{ readonly cause: unknown }> {}

export class ExternalResourceProviderFailure extends Data.TaggedError(
  "ExternalResourceProviderFailure",
)<{
  readonly provider: ExternalResourceProviderName
  readonly cause: unknown
}> {}

export type ExternalResourceSearchError =
  | ExternalResourceInputError
  | ExternalResourceAccessFailure
  | ExternalResourceProviderFailure

export interface ExternalResourceSearchShape {
  readonly search: (
    input: ExternalResourceSearchInput,
  ) => Effect.Effect<
    readonly ExternalResourceRecord[],
    ExternalResourceSearchError
  >
}

export class ExternalResourceSearch extends Context.Service<
  ExternalResourceSearch,
  ExternalResourceSearchShape
>()("@inline/server/external-resources/ExternalResourceSearch") {}

export interface ExternalResourceSearchDependencies {
  readonly resolveSpaceId: (
    peerId: InputPeer,
    currentUserId: number,
  ) => Promise<number | null>
  readonly resolveConnection: (
    provider: ExternalResourceProviderName,
    currentUserId: number,
    spaceId: number | null,
  ) => Promise<IntegrationAuthToken | null>
  readonly resolveConnections?: (
    provider: ExternalResourceProviderName,
    currentUserId: number,
    spaceId: number | null,
  ) => Promise<readonly IntegrationAuthToken[]>
  readonly searchNotion: (
    connection: IntegrationAuthToken,
    query: string,
    limit: number,
  ) => Promise<readonly ExternalResourceRecord[]>
}

export interface ExternalResourceProviderRequestLimits {
  readonly perUser: RateLimitRule
  readonly perConnection: RateLimitRule
}

export interface ExternalResourceSearchOptions {
  readonly results?: ExternalResourceCache<readonly ExternalResourceRecord[]>
  readonly connections?: ExternalResourceCache<readonly IntegrationAuthToken[]>
  readonly providerRequestLimiter?: InMemoryRateLimiter
  readonly providerRequestLimits?: ExternalResourceProviderRequestLimits
  readonly now?: () => number
}

const DEFAULT_LIMIT = 6
const MAX_LIMIT = 12
const MAX_QUERY_LENGTH = 100
const DEFAULT_PROVIDER_REQUEST_LIMITS = {
  perUser: { max: 45, windowMs: 60_000 },
  perConnection: { max: 120, windowMs: 60_000 },
} as const

export const makeExternalResourceSearch = (
  dependencies: ExternalResourceSearchDependencies,
  options: ExternalResourceSearchOptions = {},
): ExternalResourceSearchShape => {
  const resultCache = options.results ?? new ExternalResourceCache<
    readonly ExternalResourceRecord[]
  >()
  const connectionCache = options.connections ?? new ExternalResourceCache<
    readonly IntegrationAuthToken[]
  >({ maxEntries: 128, ttlMs: 10_000 })
  const providerRequestLimiter = options.providerRequestLimiter ??
    new InMemoryRateLimiter({ capacity: 1_024 })
  const providerRequestLimits = options.providerRequestLimits ??
    DEFAULT_PROVIDER_REQUEST_LIMITS
  const now = options.now ?? Date.now

  return {
    search: (input) =>
      Effect.gen(function* () {
        const query = normalizeQuery(input.query)
        if (query.length > MAX_QUERY_LENGTH) {
          return yield* Effect.fail(
            new ExternalResourceInputError({ reason: "query" }),
          )
        }

        const limit = input.limit ?? DEFAULT_LIMIT
        if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIMIT) {
          return yield* Effect.fail(
            new ExternalResourceInputError({ reason: "limit" }),
          )
        }

        const spaceId = yield* Effect.tryPromise({
          try: () => dependencies.resolveSpaceId(
            input.peerId,
            input.currentUserId,
          ),
          catch: (cause) => new ExternalResourceAccessFailure({ cause }),
        })

        const connections = yield* Effect.tryPromise({
          try: () => connectionCache.getOrLoad(
            connectionLookupKey("notion", input.currentUserId, spaceId),
            async () => dependencies.resolveConnections
              ? dependencies.resolveConnections("notion", input.currentUserId, spaceId)
              : [await dependencies.resolveConnection("notion", input.currentUserId, spaceId)]
                  .filter((connection): connection is IntegrationAuthToken => connection !== null),
          ),
          catch: (cause) => new ExternalResourceProviderFailure({
            provider: "notion",
            cause,
          }),
        })
        if (connections.length === 0) {
          return []
        }
        if (connections.some((connection) => !connectionMatchesContext(
          connection,
          input.currentUserId,
          spaceId,
        ))) {
          return yield* Effect.fail(
            new ExternalResourceAccessFailure({
              cause: new Error("Integration connection scope mismatch"),
            }),
          )
        }

        return yield* Effect.tryPromise({
          try: async () => {
            const settled = await Promise.allSettled(connections.map(async (connection) => {
              const key = resultCacheKey(connection, spaceId, query, limit)
              return resultCache.getOrLoad(key, async () => {
                if (!providerRequestAllowed(
                  providerRequestLimiter,
                  providerRequestLimits,
                  connection,
                  input.currentUserId,
                  now(),
                )) {
                  log.debug("External resource provider request skipped", {
                    provider: connection.provider,
                    reason: "rate_limit",
                    ownerType: connection.owner.type,
                  })
                  return []
                }
                return dependencies.searchNotion(connection, query, limit)
              })
            }))
            const successes = settled.flatMap((result) =>
              result.status === "fulfilled" ? [result.value] : [],
            )
            if (successes.length === 0) {
              const firstFailure = settled.find(
                (result): result is PromiseRejectedResult => result.status === "rejected",
              )
              throw firstFailure?.reason ?? new Error("All connector searches failed")
            }
            return deduplicateResources(successes.flat(), limit)
          },
          catch: (cause) => new ExternalResourceProviderFailure({
            provider: "notion",
            cause,
          }),
        })
      }),
  }
}

const liveDependencies: ExternalResourceSearchDependencies = {
  resolveSpaceId: async (peerId, currentUserId) => {
    const chat = await ChatModel.getChatFromInputPeer(peerId, {
      currentUserId,
    })
    await AccessGuards.ensureChatAccess(chat, currentUserId)
    return chat.spaceId ?? null
  },
  resolveConnection: async (provider, currentUserId, spaceId) => {
    const [connection] = await resolveIntegrationAuthCandidates(
      { provider, currentUserId, spaceId },
      userThenSpaceIntegrationAuthPolicy,
    )
    log.debug("External resource connection resolved", {
      provider,
      connected: connection !== null,
      ownerType: connection?.owner.type ?? "none",
      hasSpaceContext: spaceId !== null,
    })
    return connection ?? null
  },
  resolveConnections: async (provider, currentUserId, spaceId) => {
    const connections = await resolveIntegrationAuthCandidates(
      { provider, currentUserId, spaceId },
      userThenSpaceIntegrationAuthPolicy,
    )
    log.debug("External resource connections resolved", {
      provider,
      connectionCount: connections.length,
      ownerTypes: connections.map((connection) => connection.owner.type),
      hasSpaceContext: spaceId !== null,
    })
    return connections
  },
  searchNotion: async (connection, query, limit) => {
    log.debug("External resource provider request started", {
      provider: "notion",
      ownerType: connection.owner.type,
      queryLength: query.length,
      recent: query.length === 0,
      limit,
    })
    const resources = await searchNotionResources(connection, query, limit)
    log.debug("External resource provider request completed", {
      provider: "notion",
      resultCount: resources.length,
    })
    return resources
  },
}

const liveService = makeExternalResourceSearch(liveDependencies)

export const ExternalResourceSearchLive = Layer.succeed(
  ExternalResourceSearch,
  liveService,
)

function normalizeQuery(value: string): string {
  return value.trim().replace(/\s+/g, " ")
}

function deduplicateResources(
  resources: readonly ExternalResourceRecord[],
  limit: number,
): ExternalResourceRecord[] {
  const seen = new Set<string>()
  const result: ExternalResourceRecord[] = []
  for (const resource of resources) {
    const key = `${resource.provider}:${resource.url}`
    if (seen.has(key)) continue
    seen.add(key)
    result.push(resource)
    if (result.length === limit) break
  }
  return result
}

function connectionLookupKey(
  provider: ExternalResourceProviderName,
  currentUserId: number,
  spaceId: number | null,
): string {
  return `${provider}:user:${currentUserId}:space:${spaceId ?? "none"}`
}

function resultCacheKey(
  connection: IntegrationAuthToken,
  spaceId: number | null,
  query: string,
  limit: number,
): string {
  const owner = connection.owner.type === "user"
    ? `user:${connection.owner.userId}`
    : `space:${connection.owner.spaceId}`
  return `${connection.provider}:integration:${connection.integrationId}:${owner}:context-space:${spaceId ?? "none"}:${limit}:${query.toLowerCase()}`
}

function connectionMatchesContext(
  connection: IntegrationAuthToken,
  currentUserId: number,
  spaceId: number | null,
): boolean {
  return connection.owner.type === "user"
    ? connection.owner.userId === currentUserId
    : connection.owner.spaceId === spaceId
}

function providerRequestAllowed(
  limiter: InMemoryRateLimiter,
  limits: ExternalResourceProviderRequestLimits,
  connection: IntegrationAuthToken,
  currentUserId: number,
  nowMs: number,
): boolean {
  const owner = connection.owner.type === "user"
    ? `user:${connection.owner.userId}`
    : `space:${connection.owner.spaceId}`
  const connectionKey = `${connection.provider}:${connection.integrationId}:${owner}`
  const userLimit = limiter.consume({
    key: `external-resource:${connectionKey}:user:${currentUserId}`,
    nowMs,
    rule: limits.perUser,
  })
  if (!userLimit.allowed) return false

  return limiter.consume({
    key: `external-resource:${connectionKey}:all-users`,
    nowMs,
    rule: limits.perConnection,
  }).allowed
}
