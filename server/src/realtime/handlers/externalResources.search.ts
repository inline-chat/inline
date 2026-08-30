import {
  ExternalResourceKind,
  ExternalResourceProvider,
  type ExternalResource,
  type SearchExternalResourcesInput,
  type SearchExternalResourcesResult,
} from "@inline-chat/protocol/core"
import {
  ExternalResourceAccessFailure,
  ExternalResourceInputError,
  ExternalResourceProviderFailure,
  ExternalResourceSearch,
  ExternalResourceSearchLive,
  type ExternalResourceKindName,
  type ExternalResourceProviderName,
  type ExternalResourceRecord,
} from "@in/server/modules/externalResources/externalResources.effect"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { Log } from "@in/server/utils/log"
import { Cause, Effect } from "effect"

const log = new Log("realtime.searchExternalResources")

export const searchExternalResources = async (
  input: SearchExternalResourcesInput,
  handlerContext: HandlerContext,
): Promise<SearchExternalResourcesResult> => {
  const queryLength = input.query.trim().length
  log.debug("External resource search requested", {
    queryLength,
    recent: queryLength === 0,
    limit: input.limit ?? 6,
    isBot: handlerContext.isBot,
  })

  // Agent access needs an explicit integration permission model. Until then,
  // bots get the same cheap no-op as users without a connection.
  if (handlerContext.isBot) {
    log.debug("External resource search completed", {
      resultCount: 0,
      reason: "bot_no_op",
    })
    return { resources: [] }
  }

  const exit = await Effect.runPromiseExit(
    Effect.gen(function* () {
      const search = yield* ExternalResourceSearch
      return yield* search.search({
        peerId: input.peerId,
        currentUserId: handlerContext.userId,
        query: input.query,
        limit: input.limit,
      })
    }).pipe(Effect.provide(ExternalResourceSearchLive)),
  )

  if (exit._tag === "Failure") {
    const error = Cause.squash(exit.cause)
    if (error instanceof ExternalResourceInputError) {
      log.debug("External resource search rejected", { reason: "input" })
      throw RealtimeRpcError.BadRequest()
    }
    if (error instanceof ExternalResourceAccessFailure) {
      log.debug("External resource search rejected", { reason: "access" })
      throw RealtimeRpcError.PeerIdInvalid()
    }
    if (error instanceof ExternalResourceProviderFailure) {
      log.warn("External resource provider search failed", {
        provider: error.provider,
        causeName: error.cause instanceof Error
          ? error.cause.name
          : "UnknownError",
      })
      throw RealtimeRpcError.InternalError()
    }
    throw RealtimeRpcError.InternalError()
  }

  log.debug("External resource search completed", {
    resultCount: exit.value.length,
  })
  return {
    resources: exit.value.map(encodeResource),
  }
}

function encodeResource(resource: ExternalResourceRecord): ExternalResource {
  return {
    id: resource.id,
    provider: encodeProvider(resource.provider),
    kind: encodeKind(resource.kind),
    title: resource.title,
    url: resource.url,
    subtitle: resource.subtitle,
    emoji: resource.emoji,
  }
}

function encodeProvider(
  provider: ExternalResourceProviderName,
): ExternalResourceProvider {
  switch (provider) {
    case "notion":
      return ExternalResourceProvider.NOTION
    case "linear":
      return ExternalResourceProvider.LINEAR
    case "github":
      return ExternalResourceProvider.GITHUB
  }
}

function encodeKind(kind: ExternalResourceKindName): ExternalResourceKind {
  switch (kind) {
    case "page":
      return ExternalResourceKind.PAGE
    case "database":
      return ExternalResourceKind.DATABASE
    case "issue":
      return ExternalResourceKind.ISSUE
    case "pullRequest":
      return ExternalResourceKind.PULL_REQUEST
    case "repository":
      return ExternalResourceKind.REPOSITORY
    case "other":
      return ExternalResourceKind.OTHER
  }
}
