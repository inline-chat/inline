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
import { searchNotionResources, type NotionSearchObject } from "./notion"
import { rankExternalResources } from "./ranking"

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
  readonly parentKind?: "workspace" | "page" | "database" | undefined
  readonly lastEditedTime?: string | undefined
}

export interface ExternalResourceSearchInput {
  readonly peerId?: InputPeer | undefined
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
    object?: NotionSearchObject,
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

        const peerId = input.peerId
        // Before a chat exists, only the requesting user's personal connector is eligible.
        const spaceId = peerId === undefined ? null : yield* Effect.tryPromise({
          try: () => dependencies.resolveSpaceId(peerId, input.currentUserId),
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
            const plan: { object?: NotionSearchObject; limit: number }[] = query
              ? [{ object: "data_source", limit: 12 }, { object: "page", limit: 24 }]
              : [{ limit }]
            const settled = await Promise.allSettled(connections.flatMap((connection) => plan.map(async (request) => {
              const key = `${resultCacheKey(connection, spaceId, query, request.limit)}:${request.object ?? "recent"}`
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
                  // Reject the load so a temporary throttle is never cached as an empty search.
                  throw new ExternalResourceProviderFailure({
                    provider: "notion",
                    cause: new Error("External resource provider request limited"),
                  })
                }
                return dependencies.searchNotion(connection, query, request.limit, request.object)
              })
            })))
            const successes = settled.flatMap((result) =>
              result.status === "fulfilled" ? [result.value] : [],
            )
            const resources = successes.flat()
            // An incomplete empty search is unknown, not a cacheable "no matches" result.
            if (successes.length === 0 || (resources.length === 0 && successes.length < settled.length)) {
              const firstFailure = settled.find(
                (result): result is PromiseRejectedResult => result.status === "rejected",
              )
              throw firstFailure?.reason ?? new Error("All connector searches failed")
            }
            return rankExternalResources(resources, query, limit)
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
  searchNotion: async (connection, query, limit, object) => {
    log.debug("External resource provider request started", {
      provider: "notion",
      ownerType: connection.owner.type,
      queryLength: query.length,
      recent: query.length === 0,
      limit,
      object: object ?? "recent",
    })
    const resources = await searchNotionResources(connection, query, limit, object)
    log.debug("External resource provider request completed", {
      provider: "notion",
      resultCount: resources.length,
      object: object ?? "recent",
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
    key: `external-resource:${connection.provider}:user:${currentUserId}`,
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
