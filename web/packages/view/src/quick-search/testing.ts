/**
 * Fakes for Quick Search's async sources, for tests and labs.
 *
 * - `scriptedMessageSource` / `scriptedRemoteSource`: every call is recorded
 *   and settles only when the test says so.
 * - `fakeMessageSource` / `fakeRemoteSource`: search a fixed list, after an
 *   optional latency on an injected clock. They stand in for the core's
 *   full-text query and the server until those exist.
 * - `staticLocalSource`: a local source over writable signals.
 *
 * Every fake rejects with an `AbortError` when its signal aborts.
 */

import type { UserRow } from "@inline/core-protocol"
import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"
import { signal, type Clock, type Signal } from "@inline/reactive"
import { matchFields, normalizeText, prepareQuery } from "./match"
import {
  isMessageSearchable,
  messageSnippet,
  remoteUserFields,
  type ChatCandidate,
  type MessageHit,
  type MessageSearchRequest,
  type QuickSearchLocalSource,
  type QuickSearchMessageSource,
  type QuickSearchRemoteSource,
  type RemoteSearchRequest,
  type RemoteSearchResult,
  type SpaceCandidate,
  type UserCandidate,
} from "./sources"

export const abortError = (): Error => {
  const error = new Error("Aborted")
  error.name = "AbortError"
  return error
}

export type ScriptedCall<Request, Result> = {
  readonly request: Request
  readonly signal: AbortSignal
  resolve(result: Result): void
  reject(error: unknown): void
}

const scripted = <Request, Result>() => {
  const calls: ScriptedCall<Request, Result>[] = []
  const search = (request: Request, signal: AbortSignal): Promise<Result> =>
    new Promise<Result>((resolve, reject) => {
      calls.push({ request, signal, resolve, reject })
      signal.addEventListener("abort", () => reject(abortError()), { once: true })
    })
  return { calls, search }
}

export const scriptedMessageSource = (): {
  readonly source: QuickSearchMessageSource
  readonly calls: ScriptedCall<MessageSearchRequest, readonly MessageHit[]>[]
} => {
  const { calls, search } = scripted<MessageSearchRequest, readonly MessageHit[]>()
  return { source: { search }, calls }
}

export const scriptedRemoteSource = (): {
  readonly source: QuickSearchRemoteSource
  readonly calls: ScriptedCall<RemoteSearchRequest, RemoteSearchResult>[]
} => {
  const { calls, search } = scripted<RemoteSearchRequest, RemoteSearchResult>()
  return { source: { search }, calls }
}

const delayed = <T>(
  clock: Pick<Clock, "setTimeout" | "clearTimeout"> | undefined,
  latencyMs: number,
  signal: AbortSignal,
  produce: () => T,
): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    if (signal.aborted) {
      reject(abortError())
      return
    }
    if (!clock || latencyMs <= 0) {
      resolve(produce())
      return
    }
    const timer = clock.setTimeout(() => resolve(produce()), latencyMs)
    signal.addEventListener(
      "abort",
      () => {
        clock.clearTimeout(timer)
        reject(abortError())
      },
      { once: true },
    )
  })

export type FakeMessage = {
  readonly chatId: ChatID
  readonly messageId: MessageID
  readonly chatTitle: string
  readonly text: string
  /** Seconds since the epoch. */
  readonly date: number
  readonly spaceId?: SpaceID
  readonly peerUserId?: UserID
  readonly fromId?: UserID
}

/**
 * A message search over a list, with the FTS5 prefix semantics the core
 * will use: every query word must start a word of the message. Newest first.
 */
export const fakeMessageSource = (options: {
  readonly messages: readonly FakeMessage[]
  readonly clock?: Pick<Clock, "setTimeout" | "clearTimeout">
  readonly latencyMs?: number
}): QuickSearchMessageSource & { readonly requests: MessageSearchRequest[] } => {
  const requests: MessageSearchRequest[] = []
  return {
    requests,
    search: (request, signal) => {
      requests.push(request)
      return delayed(options.clock, options.latencyMs ?? 0, signal, () => {
        if (!isMessageSearchable(request.query)) return []
        const words = normalizeText(request.query).split(" ").filter(Boolean)
        return options.messages
          .filter((message) => request.spaceId === undefined || message.spaceId === request.spaceId)
          .filter((message) => {
            const tokens = normalizeText(message.text).split(" ")
            return words.every((word) => tokens.some((token) => token.startsWith(word)))
          })
          .sort((a, b) => b.date - a.date)
          .slice(0, request.limit)
          .map((message): MessageHit => {
            const { snippet, ranges } = messageSnippet(message.text, request.query)
            return {
              chatId: message.chatId,
              messageId: message.messageId,
              chatTitle: message.chatTitle,
              date: message.date,
              snippet,
              snippetRanges: ranges,
              ...(message.spaceId !== undefined ? { spaceId: message.spaceId } : {}),
              ...(message.peerUserId !== undefined ? { peerUserId: message.peerUserId } : {}),
              ...(message.fromId !== undefined ? { fromId: message.fromId } : {}),
            }
          })
      })
    },
  }
}

/** A server user search over a list: people whose name, username or email the query matches. */
export const fakeRemoteSource = (options: {
  readonly users: readonly UserRow[]
  readonly messages?: readonly MessageHit[]
  readonly clock?: Pick<Clock, "setTimeout" | "clearTimeout">
  readonly latencyMs?: number
}): QuickSearchRemoteSource & { readonly requests: RemoteSearchRequest[] } => {
  const requests: RemoteSearchRequest[] = []
  return {
    requests,
    search: (request, signal) => {
      requests.push(request)
      return delayed(options.clock, options.latencyMs ?? 0, signal, () => {
        const query = prepareQuery(request.query)
        if (!query) return { users: [] }
        const users = options.users.filter((user) => matchFields(query, remoteUserFields(user))).slice(0, request.limit)
        return { users, ...(options.messages ? { messages: options.messages } : {}) }
      })
    },
  }
}

/** A local source over writable signals. */
export const staticLocalSource = (initial: {
  readonly chats?: readonly ChatCandidate[]
  readonly users?: readonly UserCandidate[]
  readonly spaces?: readonly SpaceCandidate[]
} = {}): QuickSearchLocalSource & {
  readonly chats: Signal<readonly ChatCandidate[]>
  readonly users: Signal<readonly UserCandidate[]>
  readonly spaces: Signal<readonly SpaceCandidate[]>
} => ({
  chats: signal(initial.chats ?? []),
  users: signal(initial.users ?? []),
  spaces: signal(initial.spaces ?? []),
})
