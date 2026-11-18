/**
 * Local message search for UI contexts (`searchMessages`, `findInChat`,
 * `countMessages` queries). A search is a request and its answer, carried
 * as a subscription: subscribing runs it, the `search` resource carries the
 * answer, and subscribing the same `sub` again (a new request) or
 * unsubscribing aborts it, so a superseded request never delivers a result.
 *
 * The engine (`../search`) is created after the replica opens, starts its
 * background backfill only once the core has published its first ready
 * result (`startSoon`), and is stopped before the store closes.
 */
import type {
  FindInChatHit,
  QueryDescriptor,
  SearchIndexState,
  SearchMessageHit,
  SearchResource,
} from "@inline/core-protocol"
import { messageId as makeMessageId, type ChatID, type SpaceID } from "@inline/ids"
import type { Log } from "@inline/log"
import type { Db } from "../database"
import { DbObjectKind } from "../database/models"
import { displayName } from "../queries/membership"
import { isPositiveId } from "../queries/validate"
import type { ReplicaView } from "../queries/view"
import { createMessageSearch, type MessageSearch, type MessageSearchHit, type MessageSearchIndexStatus } from "../search"

type SearchQuery = Extract<QueryDescriptor, { kind: "searchMessages" | "findInChat" | "countMessages" }>

type Running = { controller: AbortController; resource: SearchResource }

const MAX_QUERY = 512

export type HostSearchOptions = {
  db: Db
  view: ReplicaView
  onChange: (handle: number) => void
  /** The index state changed (for the `core` resource). */
  onStatus: () => void
  /** Delay between the first ready publish and the backfill. */
  startDelayMs: number
  log: Log
}

const optionalCursor = (value: unknown) => value === undefined || (typeof value === "string" && value.length <= 256)
const optionalLimit = (value: unknown) =>
  value === undefined || (Number.isSafeInteger(value) && (value as number) >= 1 && (value as number) <= 100)

export class HostSearch {
  readonly engine: MessageSearch | undefined
  private readonly running = new Map<number, Running>()
  private startTimer: ReturnType<typeof setTimeout> | undefined
  private started = false
  private stopped = false
  private readonly unsubscribe: (() => void) | undefined

  constructor(private readonly options: HostSearchOptions) {
    this.engine = createMessageSearch(options.db)
    this.unsubscribe = this.engine?.subscribe(() => options.onStatus())
  }

  /** The `core` resource's `searchIndex`; absent without an index or before it starts. */
  indexState(): SearchIndexState | undefined {
    const status: MessageSearchIndexStatus | undefined = this.engine?.status()
    switch (status?.state) {
      case "building":
        return { state: "building", indexed: status.indexed, total: status.total }
      case "ready":
        return { state: "ready" }
      case "failed":
        return { state: "failed" }
      default:
        return undefined
    }
  }

  /** The first ready result went out: start the backfill after a pause (never before first paint). */
  startSoon() {
    if (this.started || this.stopped || !this.engine) return
    this.started = true
    this.startTimer = setTimeout(() => {
      this.startTimer = undefined
      if (!this.stopped) this.engine?.start()
    }, this.options.startDelayMs)
  }

  resource(handle: number): SearchResource | undefined {
    return this.running.get(handle)?.resource
  }

  open(handle: number, query: QueryDescriptor) {
    if (query.kind !== "searchMessages" && query.kind !== "findInChat" && query.kind !== "countMessages") return
    this.close(handle)
    const running: Running = { controller: new AbortController(), resource: { kind: "search", status: "pending" } }
    this.running.set(handle, running)
    const fail = (reason: "unavailable" | "invalid" | "storage") => {
      running.resource = { kind: "search", status: "failed", reason }
      this.options.onChange(handle)
    }
    if (!this.engine || this.stopped) return fail("unavailable")
    if (!this.valid(query)) return fail("invalid")
    void this.run(query, running.controller.signal).then(
      (resource) => {
        if (running.controller.signal.aborted || this.running.get(handle) !== running) return
        running.resource = resource
        this.options.onChange(handle)
      },
      (error: unknown) => {
        if (running.controller.signal.aborted || this.running.get(handle) !== running) return
        const message = error instanceof Error ? error.message : ""
        this.options.log.warn("search.failed", { error })
        fail(/cursor/i.test(message) ? "invalid" : "storage")
      },
    )
  }

  close(handle: number) {
    const running = this.running.get(handle)
    if (!running) return
    this.running.delete(handle)
    running.controller.abort()
  }

  /** Before the store closes: abort requests and stop the engine. */
  async stop() {
    if (this.stopped) return
    this.stopped = true
    if (this.startTimer) clearTimeout(this.startTimer)
    for (const running of this.running.values()) running.controller.abort()
    this.running.clear()
    this.unsubscribe?.()
    await this.engine?.stop()
  }

  // -------------------------------------------------------------------------

  private valid(query: SearchQuery): boolean {
    const request = query.request as Record<string, unknown>
    if (typeof request.query !== "string" || request.query.length > MAX_QUERY) return false
    if (!optionalCursor(request.cursor) || !optionalLimit(request.limit)) return false
    switch (query.kind) {
      case "searchMessages":
        return (
          (request.spaceId === undefined || isPositiveId(request.spaceId)) &&
          (request.includeArchived === undefined || typeof request.includeArchived === "boolean") &&
          (request.sort === undefined || request.sort === "newest" || request.sort === "relevance")
        )
      case "findInChat":
        return (
          isPositiveId(request.chatId) &&
          (request.direction === undefined || request.direction === "older" || request.direction === "newer")
        )
      case "countMessages":
        return request.chatId === undefined || isPositiveId(request.chatId)
    }
  }

  private async run(query: SearchQuery, signal: AbortSignal): Promise<SearchResource> {
    const engine = this.engine!
    switch (query.kind) {
      case "searchMessages": {
        const request = query.request
        const page = await engine.search(
          {
            query: request.query,
            ...(request.spaceId ? { spaceId: request.spaceId } : {}),
            ...(request.includeArchived !== undefined ? { includeArchived: request.includeArchived } : {}),
            ...(request.sort ? { sort: request.sort } : {}),
            ...(request.limit ? { limit: request.limit } : {}),
            ...(request.cursor ? { cursor: request.cursor } : {}),
          },
          signal,
        )
        return {
          kind: "search",
          status: "done",
          result: {
            kind: "messages",
            hits: page.hits.map((hit) => this.messageHit(hit)),
            ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
            indexComplete: page.indexComplete,
            truncated: page.truncated,
          },
        }
      }
      case "findInChat": {
        const request = query.request
        const page = await engine.findInChat(
          {
            chatId: request.chatId,
            query: request.query,
            ...(request.cursor ? { cursor: request.cursor } : {}),
            ...(request.direction ? { direction: request.direction } : {}),
            ...(request.limit ? { limit: request.limit } : {}),
          },
          signal,
        )
        return {
          kind: "search",
          status: "done",
          result: {
            kind: "findInChat",
            hits: page.hits.map(
              (hit): FindInChatHit => ({
                messageId: hit.messageId,
                fromId: hit.fromId,
                date: hit.date,
                out: hit.out,
                text: hit.text,
                ranges: hit.ranges.map((range) => [range[0], range[1]] as const),
                cursor: hit.cursor,
              }),
            ),
            hasOlder: page.hasOlder,
            hasNewer: page.hasNewer,
            ...(page.olderCursor ? { olderCursor: page.olderCursor } : {}),
            ...(page.newerCursor ? { newerCursor: page.newerCursor } : {}),
            indexComplete: page.indexComplete,
            truncated: page.truncated,
          },
        }
      }
      case "countMessages": {
        const request = query.request
        const count = await engine.count(
          { query: request.query, ...(request.chatId ? { chatId: request.chatId } : {}) },
          signal,
        )
        return {
          kind: "search",
          status: "done",
          result: { kind: "count", count: count.count, capped: count.capped, indexComplete: count.indexComplete },
        }
      }
    }
  }

  /** Quick Search's hit: the engine's fields plus the chat's sidebar title, peer and space. */
  private messageHit(hit: MessageSearchHit): SearchMessageHit {
    const view = this.options.view
    const chat = view.get(DbObjectKind.Chat, hit.chatId)
    const dialog = view.all(DbObjectKind.Dialog).find((candidate) => candidate.chatId === hit.chatId)
    const peerUserId = chat?.peerUserId ?? dialog?.peerUserId
    const peer = peerUserId ? view.get(DbObjectKind.User, peerUserId) : undefined
    const chatTitle = peerUserId ? displayName(peer) : chat?.title?.trim() || "Untitled"
    const spaceId: SpaceID | undefined = chat?.spaceId ?? dialog?.spaceId
    return {
      chatId: hit.chatId as ChatID,
      messageId: makeMessageId(hit.messageId),
      chatTitle,
      ...(peerUserId ? { peerUserId } : {}),
      ...(spaceId ? { spaceId } : {}),
      fromId: hit.fromId,
      date: hit.date,
      snippet: hit.snippet,
      ...(hit.snippetRanges.length > 0
        ? { snippetRanges: hit.snippetRanges.map((range) => [range[0], range[1]] as const) }
        : {}),
    }
  }
}
