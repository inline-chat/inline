/**
 * Server search for UI contexts (`searchServerMessages`, `searchUsers`), as
 * request and answer like local search (`search.ts`): subscribing runs it,
 * the `remoteSearch` resource carries the answer, and a replaced or released
 * request never delivers.
 *
 * Read only: nothing is written to the replica. Message hits carry their
 * text and ranges (computed here with the local search's matcher, so they
 * highlight like local hits); people are plain `UserRow` values in the
 * resource. Offline, a request fails at once with `offline` (nothing is
 * queued: a search is worth nothing later).
 */
import type { User as ProtocolUser } from "@inline-chat/protocol/core"
import type {
  QueryDescriptor,
  RemoteSearchResource,
  ServerMessageHit,
  UserRow,
} from "@inline/core-protocol"
import { messageId as makeMessageId, userId as makeUserId, type ChatID } from "@inline/ids"
import type { Log } from "@inline/log"
import type { Db } from "../database"
import { isPositiveId } from "../queries/validate"
import type { RealtimeClient } from "../realtime/realtime"
import { TransactionFailure } from "../realtime/transactions"
import { searchMessages } from "../realtime/transactions/search-messages"
import { searchUsers } from "../realtime/transactions/search-users"
import { isSearchableQuery, matchRanges, parseQuery } from "../search"
import { inputPeerForChat } from "./peers"

type RemoteQuery = Extract<QueryDescriptor, { kind: "searchServerMessages" | "searchUsers" }>

type Running = { live: boolean; resource: RemoteSearchResource }

const MAX_QUERY = 512

export type HostRemoteSearchOptions = {
  db: Db
  realtime: RealtimeClient
  userId: string
  online: () => boolean
  onChange: (handle: number) => void
  track: <T>(task: Promise<T>) => Promise<T>
  log: Log
}

/** A user found by the server, as a row value (not stored). */
export const searchUserRow = (user: ProtocolUser): UserRow => ({
  kind: "user",
  id: makeUserId(user.id),
  ...(user.firstName ? { firstName: user.firstName } : {}),
  ...(user.lastName ? { lastName: user.lastName } : {}),
  ...(user.username ? { username: user.username } : {}),
  ...(user.bot ? { bot: true } : {}),
  ...(user.profilePhoto?.cdnUrl ? { photoUrl: user.profilePhoto.cdnUrl } : {}),
})

const limitWithin = (value: unknown, max: number) =>
  value === undefined || (Number.isSafeInteger(value) && (value as number) >= 1 && (value as number) <= max)

export const isValidRemoteSearch = (query: RemoteQuery): boolean => {
  const request = query.request as Record<string, unknown> | null
  if (request == null || typeof request !== "object") return false
  if (typeof request.query !== "string" || request.query.length > MAX_QUERY) return false
  if (query.kind === "searchUsers") {
    return request.query.trim().replace(/^@/, "").length >= 2 && limitWithin(request.limit, 20)
  }
  return (
    isPositiveId(request.chatId) &&
    isSearchableQuery(request.query) &&
    (request.offsetId === undefined || isPositiveId(request.offsetId)) &&
    (request.countOnly === undefined || typeof request.countOnly === "boolean") &&
    limitWithin(request.limit, 100)
  )
}

export class HostRemoteSearch {
  private readonly running = new Map<number, Running>()
  private stopped = false

  constructor(private readonly options: HostRemoteSearchOptions) {}

  resource(handle: number): RemoteSearchResource | undefined {
    return this.running.get(handle)?.resource
  }

  open(handle: number, query: RemoteQuery) {
    this.close(handle)
    const running: Running = { live: true, resource: { kind: "remoteSearch", status: "pending" } }
    this.running.set(handle, running)
    const fail = (reason: "offline" | "invalid" | "server" | "unavailable") => {
      running.resource = { kind: "remoteSearch", status: "failed", reason }
      this.options.onChange(handle)
    }
    if (this.stopped) return fail("unavailable")
    if (!isValidRemoteSearch(query)) return fail("invalid")
    if (!this.options.online()) return fail("offline")
    void this.options.track(
      this.run(query).then(
        (resource) => {
          if (!running.live) return
          running.resource = resource
          this.options.onChange(handle)
        },
        (error: unknown) => {
          if (!running.live) return
          this.options.log.warn("remoteSearch.failed", { error })
          const kind = error instanceof TransactionFailure ? error.kind : undefined
          fail(kind === "not-connected" ? "offline" : kind === "stopped" ? "unavailable" : "server")
        },
      ),
    )
  }

  close(handle: number) {
    const running = this.running.get(handle)
    if (!running) return
    running.live = false
    this.running.delete(handle)
  }

  stop() {
    this.stopped = true
    for (const running of this.running.values()) running.live = false
    this.running.clear()
  }

  private async run(query: RemoteQuery): Promise<RemoteSearchResource> {
    const { realtime, db } = this.options
    if (query.kind === "searchUsers") {
      const transaction = searchUsers({
        query: query.request.query.trim(),
        ...(query.request.limit ? { limit: query.request.limit } : {}),
      })
      await realtime.execute(transaction)
      const users = (transaction.result?.users ?? [])
        .filter((user) => user.id > 0n && String(user.id) !== this.options.userId)
        .map(searchUserRow)
      return { kind: "remoteSearch", status: "done", result: { kind: "users", users } }
    }
    const request = query.request
    const chatId = request.chatId as ChatID
    const limit = request.limit ?? 50
    const transaction = searchMessages({
      chatId,
      peerId: inputPeerForChat(db, chatId),
      queries: [request.query.trim()],
      limit,
      ...(request.offsetId ? { offsetId: BigInt(request.offsetId) } : {}),
      ...(request.countOnly ? { countOnly: true } : {}),
    })
    await realtime.execute(transaction)
    const answer = transaction.result
    if (request.countOnly) {
      return {
        kind: "remoteSearch",
        status: "done",
        result: { kind: "count", chatId, count: Math.max(0, answer?.totalCount ?? 0) },
      }
    }
    const parsed = parseQuery(request.query)
    const messages = (answer?.messages ?? [])
      .filter((message) => String(message.chatId) === chatId && message.id > 0n)
      .sort((left, right) => (left.id > right.id ? -1 : left.id < right.id ? 1 : 0))
    const hits: ServerMessageHit[] = messages.map((message) => {
      const text = message.message ?? ""
      return {
        messageId: makeMessageId(message.id),
        fromId: makeUserId(message.fromId),
        date: Number(message.date),
        out: message.out === true,
        text,
        ranges: (parsed ? (matchRanges(text, parsed) ?? []) : []).map((range) => [range[0], range[1]] as const),
      }
    })
    const last = messages.at(-1)
    return {
      kind: "remoteSearch",
      status: "done",
      result: {
        kind: "messages",
        chatId,
        hits,
        ...(messages.length >= limit && last ? { nextOffsetId: makeMessageId(last.id) } : {}),
      },
    }
  }
}
