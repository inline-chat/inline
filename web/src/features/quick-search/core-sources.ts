/**
 * Quick Search sources backed by the account core.
 *
 * - `coreSearchRequest(client, query, signal)`: one local search request as
 *   a promise. The core carries search requests as subscriptions
 *   (`searchMessages`, `findInChat`, `countMessages`, answered by a `search`
 *   resource). Each call subscribes once, resolves with the first answer,
 *   and unsubscribes; an abort unsubscribes at once, which cancels the
 *   request in the core, and rejects with the signal's reason. A cancelled
 *   or superseded request never delivers.
 * - `createCoreMessageSource({ client, coreResource })`: the Quick Search
 *   model's `QuickSearchMessageSource` over `searchMessages`, plus signals
 *   saying whether the index was still being built.
 * - `coreRemoteRequest(client, query, signal)`: the same for the server
 *   requests (`searchUsers`, `searchServerMessages`, answered by a
 *   `remoteSearch` resource).
 * - `createCoreRemoteSource({ client })`: the model's
 *   `QuickSearchRemoteSource` over `searchUsers` (server people). Failures
 *   are quiet: the search resolves with no people and `state` says why.
 * - `createNoopRemoteSource()`: finds nothing (labs, tests, a core without
 *   server search).
 *
 * Framework-free and DOM-free.
 */

import type {
  CoreResource,
  QueryDescriptor,
  RemoteSearchResource,
  SearchIndexState,
  SearchMessageHit,
  SearchResource,
  UserRow,
} from "@inline/core-protocol"
import { effect, signal, type Dispose, type ReadSignal, type StoreClient } from "@inline/reactive"
import type {
  MessageHit,
  MessageSearchRequest,
  QuickSearchMessageSource,
  QuickSearchRemoteSource,
  RemoteSearchRequest,
  RemoteSearchResult,
} from "@inline/view/quick-search"

/** The answer of a finished search request. */
export type CoreSearchResult = Extract<SearchResource, { status: "done" }>["result"]

type SearchQuery = Extract<QueryDescriptor, { kind: "searchMessages" | "findInChat" | "countMessages" }>

type ResultFor<Q extends SearchQuery> = Q["kind"] extends "searchMessages"
  ? Extract<CoreSearchResult, { kind: "messages" }>
  : Q["kind"] extends "findInChat"
    ? Extract<CoreSearchResult, { kind: "findInChat" }>
    : Extract<CoreSearchResult, { kind: "count" }>

const resultKind = { searchMessages: "messages", findInChat: "findInChat", countMessages: "count" } as const

/** The core refused or could not answer a search request. */
export class CoreSearchError extends Error {
  readonly reason: Extract<SearchResource, { status: "failed" }>["reason"]
  constructor(reason: CoreSearchError["reason"]) {
    super(`Search failed: ${reason}`)
    this.name = "CoreSearchError"
    this.reason = reason
  }
}

const abortReason = (signal: AbortSignal | undefined): unknown => {
  const reason: unknown = signal?.reason
  if (reason !== undefined) return reason
  const error = new Error("Aborted")
  error.name = "AbortError"
  return error
}

/** Whether a rejection is an abort (ours or the signal's reason). */
export const isAbortError = (error: unknown): boolean =>
  typeof error === "object" && error !== null && (error as { name?: unknown }).name === "AbortError"

/**
 * Run one search request through the core: subscribe, wait for the first
 * `done` or `failed` resource, unsubscribe. Aborting unsubscribes and
 * rejects with the signal's reason. Patches reach the store in the frame
 * lane, so the answer arrives at the earliest in the frame after the core
 * replies.
 */
export const coreSearchRequest = <Q extends SearchQuery>(
  client: Pick<StoreClient, "subscribe">,
  query: Q,
  signal?: AbortSignal,
): Promise<ResultFor<Q>> =>
  new Promise<ResultFor<Q>>((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortReason(signal))
      return
    }
    const handle = client.subscribe(query)
    let settled = false
    let stop: Dispose | undefined
    const release = () => {
      signal?.removeEventListener("abort", onAbort)
      stop?.()
      stop = undefined
      handle.unsubscribe()
    }
    const onAbort = () => {
      if (settled) return
      settled = true
      release()
      reject(abortReason(signal))
    }
    signal?.addEventListener("abort", onAbort, { once: true })
    stop = effect(() => {
      const value = handle.resource.get()
      if (settled || value?.kind !== "search" || value.status === "pending") return
      settled = true
      // Release outside the effect's own run.
      queueMicrotask(release)
      if (value.status === "failed") {
        reject(new CoreSearchError(value.reason))
        return
      }
      if (value.result.kind !== resultKind[query.kind]) {
        reject(new CoreSearchError("invalid"))
        return
      }
      resolve(value.result as ResultFor<Q>)
    })
  })

/** A core hit as Quick Search's `MessageHit` (the same shape; copied so no extra fields leak). */
export const toMessageHit = (hit: SearchMessageHit): MessageHit => ({
  chatId: hit.chatId,
  messageId: hit.messageId,
  chatTitle: hit.chatTitle,
  ...(hit.peerUserId !== undefined ? { peerUserId: hit.peerUserId } : {}),
  ...(hit.spaceId !== undefined ? { spaceId: hit.spaceId } : {}),
  ...(hit.fromId !== undefined ? { fromId: hit.fromId } : {}),
  date: hit.date,
  snippet: hit.snippet,
  ...(hit.snippetRanges !== undefined ? { snippetRanges: hit.snippetRanges } : {}),
})

export interface CoreMessageSource extends QuickSearchMessageSource {
  /**
   * The core's index state (`CoreResource.searchIndex`), when a core
   * resource was given: `building` with progress while messages are still
   * being indexed. Undefined when the core has no index or no resource.
   */
  readonly searchIndex: ReadSignal<SearchIndexState | undefined>
  /**
   * Whether the last answered request searched a complete index. Undefined
   * before the first answer. While false, results may be missing older
   * messages (show "Still indexing messages…").
   *
   * TODO(contract): `QuickSearchMessageSource.search` returns hits only, so
   * the Quick Search model cannot say "index incomplete" itself; a view can
   * read this signal until the model's interface carries it (see README).
   */
  readonly resultsComplete: ReadSignal<boolean | undefined>
  /** Requests answered, cancelled and failed (diagnostics, labs, tests). */
  readonly stats: () => { readonly answered: number; readonly cancelled: number; readonly failed: number }
}

export type CoreMessageSourceOptions = {
  /** The session's store client (`session.client`). */
  readonly client: Pick<StoreClient, "subscribe">
  /** The session's `core` resource (`session.coreResource`), for the index state. */
  readonly coreResource?: ReadSignal<CoreResource | undefined>
}

const noIndex: ReadSignal<SearchIndexState | undefined> = { get: () => undefined, peek: () => undefined }

/** Quick Search's local message source over the core's `searchMessages` request. */
export const createCoreMessageSource = (options: CoreMessageSourceOptions): CoreMessageSource => {
  const { client, coreResource } = options
  const resultsComplete = signal<boolean | undefined>(undefined)
  const counts = { answered: 0, cancelled: 0, failed: 0 }
  const searchIndex: ReadSignal<SearchIndexState | undefined> = coreResource
    ? { get: () => coreResource.get()?.searchIndex, peek: () => coreResource.peek()?.searchIndex }
    : noIndex
  return {
    searchIndex,
    resultsComplete,
    stats: () => ({ ...counts }),
    search: async (request: MessageSearchRequest, abort: AbortSignal) => {
      try {
        const result = await coreSearchRequest(
          client,
          {
            kind: "searchMessages",
            request: {
              query: request.query,
              ...(request.spaceId !== undefined ? { spaceId: request.spaceId } : {}),
              limit: request.limit,
              includeArchived: request.includeArchived,
              sort: request.sort,
            },
          },
          abort,
        )
        counts.answered++
        resultsComplete.set(result.indexComplete)
        return result.hits.map(toMessageHit)
      } catch (error) {
        if (isAbortError(error) || abort.aborted) counts.cancelled++
        else counts.failed++
        throw error
      }
    },
  }
}

// ---------------------------------------------------------------------------
// Server search (`remoteSearch` resource)

/** The answer of a finished server request. */
export type CoreRemoteResult = Extract<RemoteSearchResource, { status: "done" }>["result"]

/** Why a server request failed (`offline` at once when not connected). */
export type RemoteFailureReason = Extract<RemoteSearchResource, { status: "failed" }>["reason"]

type RemoteQuery = Extract<QueryDescriptor, { kind: "searchUsers" | "searchServerMessages" }>

type RemoteResultFor<Q extends RemoteQuery> = Q["kind"] extends "searchUsers"
  ? Extract<CoreRemoteResult, { kind: "users" }>
  : Extract<CoreRemoteResult, { kind: "messages" | "count" }>

/** The core refused or could not answer a server request. */
export class CoreRemoteSearchError extends Error {
  readonly reason: RemoteFailureReason
  constructor(reason: RemoteFailureReason) {
    super(`Server search failed: ${reason}`)
    this.name = "CoreRemoteSearchError"
    this.reason = reason
  }
}

/**
 * Run one server request through the core: subscribe, wait for the first
 * `done` or `failed` `remoteSearch` resource, unsubscribe. Aborting
 * unsubscribes (which cancels the request in the core) and rejects with the
 * signal's reason; a cancelled request never delivers.
 */
export const coreRemoteRequest = <Q extends RemoteQuery>(
  client: Pick<StoreClient, "subscribe">,
  query: Q,
  signal?: AbortSignal,
): Promise<RemoteResultFor<Q>> =>
  new Promise<RemoteResultFor<Q>>((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortReason(signal))
      return
    }
    const handle = client.subscribe(query)
    let settled = false
    let stop: Dispose | undefined
    const release = () => {
      signal?.removeEventListener("abort", onAbort)
      stop?.()
      stop = undefined
      handle.unsubscribe()
    }
    const onAbort = () => {
      if (settled) return
      settled = true
      release()
      reject(abortReason(signal))
    }
    signal?.addEventListener("abort", onAbort, { once: true })
    stop = effect(() => {
      const value = handle.resource.get()
      if (settled || value?.kind !== "remoteSearch" || value.status === "pending") return
      settled = true
      queueMicrotask(release)
      if (value.status === "failed") {
        reject(new CoreRemoteSearchError(value.reason))
        return
      }
      const kindOk = query.kind === "searchUsers" ? value.result.kind === "users" : value.result.kind !== "users"
      if (!kindOk) {
        reject(new CoreRemoteSearchError("invalid"))
        return
      }
      resolve(value.result as RemoteResultFor<Q>)
    })
  })

/** What the server people search is doing, for a quiet status in the palette. */
export type RemotePeopleState =
  | { readonly status: "idle" }
  | { readonly status: "pending"; readonly query: string }
  | { readonly status: "done"; readonly query: string; readonly count: number }
  | { readonly status: "failed"; readonly query: string; readonly reason: RemoteFailureReason }

export interface CoreRemoteSource extends QuickSearchRemoteSource {
  /** The latest request's state. A failure is reported here only; the search itself resolves with no people. */
  readonly state: ReadSignal<RemotePeopleState>
  /** Requests answered, cancelled and failed (diagnostics, labs, tests). */
  readonly stats: () => { readonly answered: number; readonly cancelled: number; readonly failed: number }
}

export type CoreRemoteSourceOptions = {
  /** The session's store client (`session.client`). */
  readonly client: Pick<StoreClient, "subscribe">
}

/** The server's cap on `searchUsers` (`UserSearchRequest.limit`). */
export const SEARCH_USERS_LIMIT = 20

/** At least two characters after a leading `@` (the core's rule; the model asks only then). */
const peopleQuery = (query: string): string | undefined => {
  const trimmed = query.trim().replace(/^@+/, "").trim()
  return trimmed.length >= 2 ? trimmed : undefined
}

/**
 * Server people for Quick Search (`searchUsers`, the Mac's `searchContacts`).
 *
 * Timing and placement are the model's (`QuickSearchModel`): it asks
 * `quickSearchTiming.remoteDelayMs` (250 ms, the Mac's `searchGlobalUsers`
 * sleep) after the last keystroke, aborts the previous request on every
 * new query (which unsubscribes here, so a stale answer never arrives),
 * ranks the people, drops those already shown locally (by user ID) and
 * lists the rest under "Global", below every local section.
 *
 * This source adds: one subscription per request, people deduplicated by
 * ID in server order, and a quiet failure (offline, server, unavailable):
 * the search resolves with no people, so the local results stay and no
 * error line shows; `state` says what happened.
 */
export const createCoreRemoteSource = (options: CoreRemoteSourceOptions): CoreRemoteSource => {
  const { client } = options
  const state = signal<RemotePeopleState>({ status: "idle" })
  const counts = { answered: 0, cancelled: 0, failed: 0 }
  let latest = 0
  return {
    state,
    stats: () => ({ ...counts }),
    search: async (request: RemoteSearchRequest, abort: AbortSignal): Promise<RemoteSearchResult> => {
      const query = peopleQuery(request.query)
      if (query === undefined) {
        if (abort.aborted) throw abortReason(abort)
        return { users: [] }
      }
      const token = ++latest
      state.set({ status: "pending", query })
      try {
        const result = await coreRemoteRequest(
          client,
          { kind: "searchUsers", request: { query, limit: Math.max(1, Math.min(request.limit, SEARCH_USERS_LIMIT)) } },
          abort,
        )
        counts.answered++
        const seen = new Set<string>()
        const users: UserRow[] = []
        for (const user of result.users) {
          if (seen.has(user.id)) continue
          seen.add(user.id)
          users.push(user)
        }
        if (token === latest) state.set({ status: "done", query, count: users.length })
        return { users }
      } catch (error) {
        if (isAbortError(error) || abort.aborted) {
          counts.cancelled++
          if (token === latest) state.set({ status: "idle" })
          throw error
        }
        counts.failed++
        const reason: RemoteFailureReason = error instanceof CoreRemoteSearchError ? error.reason : "unavailable"
        if (token === latest) state.set({ status: "failed", query, reason })
        return { users: [] }
      }
    },
  }
}

/** A remote source that finds nothing, at once (labs, tests, a core without server search). */
export const createNoopRemoteSource = (): QuickSearchRemoteSource => ({
  search: (_request: RemoteSearchRequest, abort: AbortSignal): Promise<RemoteSearchResult> =>
    abort.aborted ? Promise.reject(abortReason(abort)) : Promise.resolve({ users: [] }),
})
