/**
 * Where find in chat gets its matches: an interface the model pages through,
 * and its implementation over the core's local index (`findInChat` and
 * `countMessages`, carried as subscriptions).
 *
 * The Mac (`InChatSearchViewModel`) pages two sources, the local index and
 * the server's `searchMessages`, and merges them by message ID. So does the
 * model here: `FindInChatSource` is the device's index, `FindServerSource`
 * (optional) the server's search in one chat (`searchServerMessages`), for
 * history the device does not hold.
 *
 * Framework-free and DOM-free.
 */

import type { FindInChatHit, QueryDescriptor, RemoteSearchResource, SearchRange, ServerMessageHit } from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { effect, type Dispose, type StoreClient } from "@inline/reactive"
import { coreSearchRequest } from "../quick-search/core-sources"

export type { FindInChatHit, SearchRange, ServerMessageHit }

export type FindPageRequest = {
  readonly chatId: ChatID
  /** The trimmed query. */
  readonly query: string
  /** Continue older than this (a cursor the source gave out). Absent for the first page. */
  readonly cursor?: string
  readonly limit: number
}

/** A page of matches, newest first. */
export type FindPage = {
  readonly hits: readonly FindInChatHit[]
  /** More matches may exist older than the last one. */
  readonly hasOlder: boolean
  /** The cursor for the next older page. */
  readonly olderCursor?: string
  /** False while the device's index is still being built: older matches may be missing. */
  readonly indexComplete: boolean
  /** The source stopped early (a work cap); `olderCursor` continues where it stopped. */
  readonly truncated: boolean
}

export type FindCount = {
  readonly count: number
  /** The count stopped at the source's cap (the core's is 10,000). */
  readonly capped: boolean
  readonly indexComplete: boolean
}

export interface FindInChatSource {
  /** A page of matches. Must reject promptly once `signal` aborts. */
  find(request: FindPageRequest, signal: AbortSignal): Promise<FindPage>
  /** How many messages in the chat match. */
  count(request: { readonly chatId: ChatID; readonly query: string }, signal: AbortSignal): Promise<FindCount>
}

/** Find in chat over the core's local index. One subscription per request; aborting unsubscribes. */
export const coreFindSource = (client: Pick<StoreClient, "subscribe">): FindInChatSource => ({
  find: async (request, signal) => {
    const result = await coreSearchRequest(
      client,
      {
        kind: "findInChat",
        request: {
          chatId: request.chatId,
          query: request.query,
          ...(request.cursor !== undefined ? { cursor: request.cursor } : {}),
          direction: "older",
          limit: request.limit,
        },
      },
      signal,
    )
    return {
      hits: result.hits,
      hasOlder: result.hasOlder,
      ...(result.olderCursor !== undefined ? { olderCursor: result.olderCursor } : {}),
      indexComplete: result.indexComplete,
      truncated: result.truncated,
    }
  },
  count: async (request, signal) => {
    const result = await coreSearchRequest(client, { kind: "countMessages", request: { chatId: request.chatId, query: request.query } }, signal)
    return { count: result.count, capped: result.capped, indexComplete: result.indexComplete }
  },
})

// ---------------------------------------------------------------------------
// Server search in one chat

export type FindServerPageRequest = {
  readonly chatId: ChatID
  /** The trimmed query. */
  readonly query: string
  /** Older than this message (the previous page's `nextOffsetId`). Absent for the first page. */
  readonly offsetId?: MessageID
  readonly limit: number
}

/** A page of server matches, newest first. */
export type FindServerPage = {
  readonly hits: readonly ServerMessageHit[]
  /** Pass as `offsetId` for the next page; absent on the last page. */
  readonly nextOffsetId?: MessageID
}

/**
 * The server's matches in one chat. Optional for the model: without it,
 * find covers what the device has indexed. Both methods must reject
 * promptly once `signal` aborts.
 */
export interface FindServerSource {
  find(request: FindServerPageRequest, signal: AbortSignal): Promise<FindServerPage>
  /** The exact number of matches in the chat. Optional. */
  count?(request: { readonly chatId: ChatID; readonly query: string }, signal: AbortSignal): Promise<number>
}

/** The core refused or could not answer a server search (`offline`, `server`, `invalid`, `unavailable`). */
export class FindServerError extends Error {
  readonly reason: Extract<RemoteSearchResource, { status: "failed" }>["reason"]
  constructor(reason: FindServerError["reason"]) {
    super(`Server search failed: ${reason}`)
    this.name = "FindServerError"
    this.reason = reason
  }
}

type ServerQuery = Extract<QueryDescriptor, { kind: "searchServerMessages" }>
type ServerResult = Extract<RemoteSearchResource, { status: "done" }>["result"]

const abortError = (signal: AbortSignal): unknown => {
  const reason: unknown = signal.reason
  if (reason !== undefined) return reason
  const error = new Error("Aborted")
  error.name = "AbortError"
  return error
}

/**
 * One `searchServerMessages` request as a promise: subscribe, resolve with
 * the first `done` answer (reject `FindServerError` on `failed`),
 * unsubscribe. Aborting unsubscribes at once, which cancels it in the core;
 * a late answer is never delivered.
 */
export const coreServerSearchRequest = (
  client: Pick<StoreClient, "subscribe">,
  query: ServerQuery,
  signal: AbortSignal,
): Promise<ServerResult> =>
  new Promise<ServerResult>((resolve, reject) => {
    if (signal.aborted) {
      reject(abortError(signal))
      return
    }
    const handle = client.subscribe(query)
    let settled = false
    let stop: Dispose | undefined
    const release = () => {
      signal.removeEventListener("abort", onAbort)
      stop?.()
      stop = undefined
      handle.unsubscribe()
    }
    const onAbort = () => {
      if (settled) return
      settled = true
      release()
      reject(abortError(signal))
    }
    signal.addEventListener("abort", onAbort, { once: true })
    stop = effect(() => {
      const value = handle.resource.get()
      if (settled || value?.kind !== "remoteSearch" || value.status === "pending") return
      settled = true
      // Release outside the effect's own run.
      queueMicrotask(() => release())
      if (value.status === "failed") reject(new FindServerError(value.reason))
      else resolve(value.result)
    })
  })

/** Find in chat over the server's `SEARCH_MESSAGES`, through the core. One subscription per request. */
export const coreServerFindSource = (client: Pick<StoreClient, "subscribe">): FindServerSource => ({
  find: async (request, signal) => {
    const result = await coreServerSearchRequest(
      client,
      {
        kind: "searchServerMessages",
        request: {
          chatId: request.chatId,
          query: request.query,
          ...(request.offsetId !== undefined ? { offsetId: request.offsetId } : {}),
          limit: request.limit,
        },
      },
      signal,
    )
    if (result.kind !== "messages") throw new FindServerError("invalid")
    return { hits: result.hits, ...(result.nextOffsetId !== undefined ? { nextOffsetId: result.nextOffsetId } : {}) }
  },
  count: async (request, signal) => {
    const result = await coreServerSearchRequest(
      client,
      { kind: "searchServerMessages", request: { chatId: request.chatId, query: request.query, countOnly: true } },
      signal,
    )
    if (result.kind !== "count") throw new FindServerError("invalid")
    return result.count
  },
})
