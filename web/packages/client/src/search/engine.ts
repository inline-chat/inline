import type { Database, PreparedStatement, SqlValue } from "@sqlite.org/sqlite-wasm"
import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"
import type { Db } from "../database"
import { decodeInlineModel } from "../database/model-codec"
import { DbObjectKind, type Message } from "../database/models"
import { messageSnippet, matchRanges, type TextRange } from "./highlight"
import {
  chatToken,
  indexStoredMessages,
  MessageSearchIndexWriter,
  type BackfillCursor,
} from "./index-writer"
import { SEARCH_NORMALIZER_VERSION } from "./normalize"
import { matchExpression, parseQuery, type ParsedQuery } from "./query"

// ---------------------------------------------------------------------------
// Types

/** The storage half the engine needs: `SQLitePersistenceStore` implements it. */
export interface MessageSearchStore {
  /** A synchronous read on committed state; never waits for queued writes. */
  readSearchIndex<T>(read: (db: Database) => T): Promise<T>
  /** A synchronous write in its own transaction, queued with every other write. */
  writeSearchIndex<T>(write: (db: Database) => T): Promise<T>
}

export const isMessageSearchStore = (store: unknown): store is MessageSearchStore =>
  typeof store === "object" &&
  store !== null &&
  typeof (store as Partial<MessageSearchStore>).readSearchIndex === "function" &&
  typeof (store as Partial<MessageSearchStore>).writeSearchIndex === "function"

export type MessageSearchSort = "newest" | "relevance"

export type MessageSearchRequest = {
  /** What the user typed. See `query.ts` for the language. */
  readonly query: string
  /** Only this chat. */
  readonly chatId?: ChatID
  /** Only chats of this space (the dialog's space, else the chat's), as on the Mac. */
  readonly spaceId?: SpaceID
  /** Default true. False leaves out archived dialogs. */
  readonly includeArchived?: boolean
  /** Default "newest": date, then message ID, newest first (Mac Quick Search). */
  readonly sort?: MessageSearchSort
  /** Default 20, at most 100. */
  readonly limit?: number
  /** `nextCursor` of the previous page. */
  readonly cursor?: string
}

export type MessageSearchHit = {
  readonly chatId: ChatID
  readonly messageId: MessageID
  readonly fromId: UserID
  /** Seconds since the epoch. */
  readonly date: number
  readonly out: boolean
  /** The message text, as stored. */
  readonly text: string
  /** Matches in `text`, UTF-16 offsets, sorted and merged. */
  readonly ranges: readonly TextRange[]
  /** An excerpt around the first match (Mac radius 70) and the matches inside it. */
  readonly snippet: string
  readonly snippetRanges: readonly TextRange[]
  /** The hit's position; a find-in-chat cursor. */
  readonly cursor: string
}

export type MessageSearchPage = {
  readonly hits: readonly MessageSearchHit[]
  /** Pass back as `cursor` for the next page; absent when there is none. */
  readonly nextCursor?: string
  /** False while the background backfill has not indexed every stored message. */
  readonly indexComplete: boolean
  /** The per-query work cap stopped the scan early; `nextCursor` continues it. */
  readonly truncated: boolean
}

export type FindInChatRequest = {
  readonly chatId: ChatID
  readonly query: string
  /** A hit's `cursor`; absent for the newest page. */
  readonly cursor?: string
  /** From `cursor`: "older" (default) or "newer". */
  readonly direction?: "older" | "newer"
  /** Default 100 (the Mac's page), at most 100. */
  readonly limit?: number
}

export type FindInChatPage = {
  /** Newest first. */
  readonly hits: readonly MessageSearchHit[]
  readonly hasOlder: boolean
  readonly hasNewer: boolean
  /** Cursors for the next older and newer pages. */
  readonly olderCursor?: string
  readonly newerCursor?: string
  readonly indexComplete: boolean
  readonly truncated: boolean
}

export type MessageSearchCount = {
  /** Matching messages in the index, up to `COUNT_CAP`. */
  readonly count: number
  /** The count reached `COUNT_CAP`: show "10,000+". */
  readonly capped: boolean
  readonly indexComplete: boolean
}

export type MessageSearchIndexStatus =
  | { readonly state: "idle" }
  | { readonly state: "building"; readonly indexed: number; readonly total: number }
  | { readonly state: "ready" }
  | { readonly state: "failed"; readonly message: string }
  | { readonly state: "stopped" }

export type MessageSearchOptions = {
  readonly db: Db
  readonly store: MessageSearchStore
  /** Messages per backfill transaction. Default 500. */
  readonly backfillBatchSize?: number
  /** Waits between backfill batches so reads and paint run. Default: a macrotask. */
  readonly pause?: () => Promise<void>
  /** Clock for the per-query budget. Default `performance.now`. */
  readonly now?: () => number
  /** Per-query budget in milliseconds. Default 60. */
  readonly maxQueryMs?: number
  /** Index rows examined per query at most. Default 20,000. */
  readonly maxScannedRows?: number
}

// ---------------------------------------------------------------------------
// Constants

export const DEFAULT_SEARCH_LIMIT = 20
export const FIND_IN_CHAT_PAGE = 100
export const MAX_SEARCH_LIMIT = 100
/** Relevance ranks the newest this many matches (bm25), so its cost is bounded. */
export const RELEVANCE_WINDOW = 1_000
export const COUNT_CAP = 10_000
const DEFAULT_MAX_QUERY_MS = 60
const DEFAULT_MAX_SCANNED = 20_000
const DEFAULT_BACKFILL_BATCH = 500
const BACKFILL_ATTEMPTS = 3
const METADATA_KEY = "message_search"

// ---------------------------------------------------------------------------
// Helpers

const abortError = (signal: AbortSignal | undefined): unknown =>
  signal?.reason ?? Object.assign(new Error("The search was aborted"), { name: "AbortError" })

const throwIfAborted = (signal: AbortSignal | undefined) => {
  if (signal?.aborted) throw abortError(signal)
}

const bigintOf = (value: SqlValue | undefined): bigint | undefined => {
  if (typeof value === "bigint") return value
  if (typeof value === "number" && Number.isInteger(value)) return BigInt(value)
  return undefined
}

const clampLimit = (limit: number | undefined, fallback: number) =>
  Number.isSafeInteger(limit) && (limit as number) > 0
    ? Math.min(limit as number, MAX_SEARCH_LIMIT)
    : fallback

type CursorValue = { kind: "rowid"; rowid: bigint } | { kind: "offset"; offset: number }

const encodeRowid = (rowid: bigint) => `n${rowid.toString(36)}`

const decodeCursor = (cursor: string | undefined): CursorValue | undefined => {
  if (cursor === undefined) return undefined
  if (typeof cursor === "string" && /^n[0-9a-z]{1,14}$/.test(cursor)) {
    let value = 0n
    for (const char of cursor.slice(1)) value = value * 36n + BigInt(parseInt(char, 36))
    return { kind: "rowid", rowid: value }
  }
  if (typeof cursor === "string" && /^r[0-9]{1,6}$/.test(cursor)) {
    return { kind: "offset", offset: Number(cursor.slice(1)) }
  }
  throw new RangeError("Invalid message search cursor")
}

type IndexState = {
  version: number
  state: "building" | "ready"
  after?: BackfillCursor
}

const readIndexState = (db: Database): IndexState => {
  const rows = db.exec({
    sql: "SELECT value FROM inline_replica_metadata WHERE key = ?",
    bind: [METADATA_KEY],
    rowMode: "array",
    returnValue: "resultRows",
  }) as SqlValue[][]
  const raw = rows[0]?.[0]
  if (typeof raw !== "string") return { version: 0, state: "building" }
  try {
    const parsed = JSON.parse(raw) as { version?: unknown; state?: unknown; after?: unknown }
    const after =
      Array.isArray(parsed.after) &&
      parsed.after.length === 2 &&
      parsed.after.every((part) => typeof part === "string" && /^-?\d+$/.test(part))
        ? ([BigInt(parsed.after[0] as string), BigInt(parsed.after[1] as string)] as const)
        : undefined
    return {
      version: typeof parsed.version === "number" ? parsed.version : 0,
      state: parsed.state === "ready" ? "ready" : "building",
      ...(after ? { after } : {}),
    }
  } catch {
    return { version: 0, state: "building" }
  }
}

const writeIndexState = (db: Database, state: IndexState) => {
  db.exec({
    sql: `INSERT INTO inline_replica_metadata(key, value, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    bind: [
      METADATA_KEY,
      JSON.stringify({
        version: state.version,
        state: state.state,
        ...(state.after ? { after: [String(state.after[0]), String(state.after[1])] } : {}),
      }),
      Date.now(),
    ],
  })
}

const isComplete = (state: IndexState) =>
  state.state === "ready" && state.version === SEARCH_NORMALIZER_VERSION

/** One index row the SQL scan accepted, before its message is read. */
type Candidate = { rowid: bigint; chatId: bigint; messageId: bigint; score: number }

type ScanResult = {
  candidates: Candidate[]
  /** Rows were left unexamined because the page filled. */
  more: boolean
  /** The budget stopped the scan. */
  truncated: boolean
  /** The last rowid examined (for continuing a truncated scan). */
  lastExamined?: bigint
  indexComplete: boolean
  payloads: Map<string, Uint8Array>
}

type ScanPlan = {
  parsed: ParsedQuery
  chatId?: ChatID
  spaceId?: SpaceID
  includeArchived: boolean
  order: "desc" | "asc"
  /** Exclusive bound in scan order. */
  bound?: bigint
  /** Rows to accept before stopping. */
  take: number
  withScore: boolean
}

const keyOf = (chatId: bigint, messageId: bigint) => `${chatId}:${messageId}`

// ---------------------------------------------------------------------------
// Engine

/**
 * Local message search over the replica's FTS5 index. One per account core,
 * beside its `Db`. Runs wherever the store runs (the core's worker).
 */
export class MessageSearch {
  private readonly db: Db
  private readonly store: MessageSearchStore
  private readonly now: () => number
  private readonly maxQueryMs: number
  private readonly maxScanned: number
  private readonly batchSize: number
  private readonly pause: () => Promise<void>
  private currentStatus: MessageSearchIndexStatus = { state: "idle" }
  private readonly listeners = new Set<(status: MessageSearchIndexStatus) => void>()
  private backfill: Promise<void> | null = null
  private stopped = false

  constructor(options: MessageSearchOptions) {
    this.db = options.db
    this.store = options.store
    this.now = options.now ?? (() => performance.now())
    this.maxQueryMs = options.maxQueryMs ?? DEFAULT_MAX_QUERY_MS
    this.maxScanned = options.maxScannedRows ?? DEFAULT_MAX_SCANNED
    this.batchSize = Math.max(1, options.backfillBatchSize ?? DEFAULT_BACKFILL_BATCH)
    this.pause = options.pause ?? (() => new Promise((resolve) => setTimeout(resolve, 0)))
  }

  // ---- Index status and backfill ----

  status(): MessageSearchIndexStatus {
    return this.currentStatus
  }

  /** Called with every status change. Returns the unsubscribe function. */
  subscribe(listener: (status: MessageSearchIndexStatus) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  private setStatus(status: MessageSearchIndexStatus) {
    this.currentStatus = status
    for (const listener of this.listeners) listener(status)
  }

  /**
   * Start indexing stored messages that are not indexed yet (a replica
   * upgraded from version 4, or a normalizer change), in the background.
   * Idempotent. Resolves when the backfill ends, fails or is stopped.
   */
  start(): Promise<void> {
    if (this.stopped) return Promise.resolve()
    this.backfill ??= this.runBackfill().finally(() => {
      this.backfill = null
    })
    return this.backfill
  }

  /** Stop the backfill after its current batch; later searches reject. */
  async stop(): Promise<void> {
    this.stopped = true
    await this.backfill?.catch(() => undefined)
    this.setStatus({ state: "stopped" })
  }

  private async runBackfill() {
    const initial = await this.store.readSearchIndex((db) => {
      const state = readIndexState(db)
      if (isComplete(state)) return { state, total: 0, done: 0 }
      const after = state.version === SEARCH_NORMALIZER_VERSION ? state.after : undefined
      const total = Number(
        (db.exec({ sql: "SELECT count(*) FROM message", rowMode: "array", returnValue: "resultRows" }) as SqlValue[][])[0]?.[0] ?? 0,
      )
      const done = after
        ? Number(
            (db.exec({
              sql: "SELECT count(*) FROM message WHERE (chat_id, message_id) <= (?, ?)",
              bind: [after[0], after[1]],
              rowMode: "array",
              returnValue: "resultRows",
            }) as SqlValue[][])[0]?.[0] ?? 0,
          )
        : 0
      return { state, total, done }
    })
    if (isComplete(initial.state)) {
      this.setStatus({ state: "ready" })
      return
    }
    let indexed = initial.done
    const total = initial.total
    let failures = 0
    this.setStatus({ state: "building", indexed, total })
    while (!this.stopped) {
      let done: boolean
      try {
        const result = await this.store.writeSearchIndex((db) => {
          const state = readIndexState(db)
          if (isComplete(state)) return { read: 0, done: true }
          const after = state.version === SEARCH_NORMALIZER_VERSION ? state.after : undefined
          const writer = new MessageSearchIndexWriter(db)
          try {
            const batch = indexStoredMessages(db, writer, after, this.batchSize)
            writeIndexState(db, {
              version: SEARCH_NORMALIZER_VERSION,
              state: batch.done ? "ready" : "building",
              ...(!batch.done && batch.last ? { after: batch.last } : {}),
            })
            return { read: batch.read, done: batch.done }
          } finally {
            writer.finalize()
          }
        })
        failures = 0
        indexed += result.read
        done = result.done
      } catch (error) {
        if (this.stopped) return
        failures += 1
        if (failures >= BACKFILL_ATTEMPTS) {
          this.setStatus({
            state: "failed",
            message: error instanceof Error ? error.message : String(error),
          })
          return
        }
        await this.pause()
        continue
      }
      if (done) {
        this.setStatus({ state: "ready" })
        return
      }
      this.setStatus({ state: "building", indexed: Math.min(indexed, Math.max(total, indexed)), total: Math.max(total, indexed) })
      await this.pause()
    }
  }

  // ---- Queries ----

  /**
   * Search messages across the account, or within one chat or space.
   * Never throws for any query text; rejects only when `signal` aborts, the
   * engine is stopped, the cursor is not one this engine produced, or
   * storage fails.
   */
  async search(request: MessageSearchRequest, signal?: AbortSignal): Promise<MessageSearchPage> {
    throwIfAborted(signal)
    this.assertRunning()
    const parsed = parseQuery(request.query)
    const limit = clampLimit(request.limit, DEFAULT_SEARCH_LIMIT)
    const cursor = decodeCursor(request.cursor)
    if (!parsed) return { hits: [], indexComplete: await this.indexComplete(), truncated: false }
    const sort = request.sort ?? "newest"
    if (sort === "relevance") {
      const offset = cursor?.kind === "offset" ? cursor.offset : 0
      const scan = await this.scan(
        {
          parsed,
          ...(request.chatId !== undefined ? { chatId: request.chatId } : {}),
          ...(request.spaceId !== undefined ? { spaceId: request.spaceId } : {}),
          includeArchived: request.includeArchived ?? true,
          order: "desc",
          take: RELEVANCE_WINDOW,
          withScore: true,
        },
        signal,
      )
      const ranked = [...scan.candidates].sort(
        (a, b) => a.score - b.score || (a.rowid < b.rowid ? 1 : a.rowid > b.rowid ? -1 : 0),
      )
      const page = ranked.slice(offset, offset + limit)
      const hits = await this.hydrate(page, scan.payloads, parsed, signal)
      const more = offset + limit < ranked.length
      return {
        hits,
        ...(more ? { nextCursor: `r${offset + limit}` } : {}),
        indexComplete: scan.indexComplete,
        truncated: scan.truncated || scan.more,
      }
    }
    const bound = cursor?.kind === "rowid" ? cursor.rowid : undefined
    const scan = await this.scan(
      {
        parsed,
        ...(request.chatId !== undefined ? { chatId: request.chatId } : {}),
        ...(request.spaceId !== undefined ? { spaceId: request.spaceId } : {}),
        includeArchived: request.includeArchived ?? true,
        order: "desc",
        ...(bound !== undefined ? { bound } : {}),
        take: limit,
        withScore: false,
      },
      signal,
    )
    const hits = await this.hydrate(scan.candidates, scan.payloads, parsed, signal)
    const last = scan.candidates[scan.candidates.length - 1]?.rowid
    const continueFrom = scan.truncated ? scan.lastExamined : scan.more ? last : undefined
    return {
      hits,
      ...(continueFrom !== undefined ? { nextCursor: encodeRowid(continueFrom) } : {}),
      indexComplete: scan.indexComplete,
      truncated: scan.truncated,
    }
  }

  /**
   * Find in chat: one chat's matches newest first, a page at a time in
   * either direction from a hit's cursor (the Mac's `InChatMessageSearch`).
   */
  async findInChat(request: FindInChatRequest, signal?: AbortSignal): Promise<FindInChatPage> {
    throwIfAborted(signal)
    this.assertRunning()
    const parsed = parseQuery(request.query)
    const limit = clampLimit(request.limit, FIND_IN_CHAT_PAGE)
    const cursor = decodeCursor(request.cursor)
    if (cursor && cursor.kind !== "rowid") throw new RangeError("Invalid find-in-chat cursor")
    if (!parsed) {
      return { hits: [], hasOlder: false, hasNewer: false, indexComplete: await this.indexComplete(), truncated: false }
    }
    const newer = request.direction === "newer"
    const scan = await this.scan(
      {
        parsed,
        chatId: request.chatId,
        includeArchived: true,
        order: newer ? "asc" : "desc",
        ...(cursor ? { bound: cursor.rowid } : {}),
        take: limit,
        withScore: false,
      },
      signal,
    )
    const ordered = newer ? [...scan.candidates].reverse() : scan.candidates
    const hits = await this.hydrate(ordered, scan.payloads, parsed, signal)
    const newest = ordered[0]?.rowid
    const oldest = ordered[ordered.length - 1]?.rowid
    const beyond = scan.more || scan.truncated
    // A truncated scan continues after the last row it examined.
    const scanFrom = scan.truncated ? (scan.lastExamined ?? cursor?.rowid) : undefined
    const hasOlder = newer ? cursor !== undefined : beyond
    const hasNewer = newer ? beyond : cursor !== undefined
    const olderFrom = newer ? (oldest ?? cursor?.rowid) : (scanFrom ?? oldest)
    const newerFrom = newer ? (scanFrom ?? newest) : (newest ?? cursor?.rowid)
    return {
      hits,
      hasOlder,
      hasNewer,
      ...(hasOlder && olderFrom !== undefined ? { olderCursor: encodeRowid(olderFrom) } : {}),
      ...(hasNewer && newerFrom !== undefined ? { newerCursor: encodeRowid(newerFrom) } : {}),
      indexComplete: scan.indexComplete,
      truncated: scan.truncated,
    }
  }

  /** How many indexed messages match, in one chat or everywhere, up to `COUNT_CAP`. */
  async count(
    request: { readonly query: string; readonly chatId?: ChatID },
    signal?: AbortSignal,
  ): Promise<MessageSearchCount> {
    throwIfAborted(signal)
    this.assertRunning()
    const parsed = parseQuery(request.query)
    if (!parsed) return { count: 0, capped: false, indexComplete: await this.indexComplete() }
    const result = await this.store.readSearchIndex((db) => {
      const rows = db.exec({
        sql: `SELECT count(*) FROM (
          SELECT 1 FROM message_search WHERE message_search MATCH ? LIMIT ?
        )`,
        bind: [
          matchExpression(parsed, request.chatId !== undefined ? chatToken(request.chatId) : undefined),
          COUNT_CAP + 1,
        ],
        rowMode: "array",
        returnValue: "resultRows",
      }) as SqlValue[][]
      return { count: Number(rows[0]?.[0] ?? 0), indexComplete: isComplete(readIndexState(db)) }
    })
    throwIfAborted(signal)
    return {
      count: Math.min(result.count, COUNT_CAP),
      capped: result.count > COUNT_CAP,
      indexComplete: result.indexComplete,
    }
  }

  private assertRunning() {
    if (this.stopped) throw new Error("Message search is stopped")
  }

  private indexComplete(): Promise<boolean> {
    return this.store.readSearchIndex((db) => isComplete(readIndexState(db)))
  }

  /**
   * Walk the index in rowid order, filter in JavaScript, and stop at `take`
   * rows or the budget. One SQLite step examines one index match, so the
   * budget is checked between bounded units of work.
   */
  private async scan(plan: ScanPlan, signal: AbortSignal | undefined): Promise<ScanResult> {
    const expression = matchExpression(
      plan.parsed,
      plan.chatId !== undefined ? chatToken(plan.chatId) : undefined,
    )
    const filtered = plan.spaceId !== undefined || !plan.includeArchived
    const comparator = plan.order === "desc" ? "<" : ">"
    const sql = `
      SELECT s.rowid, d.chat_id, d.message_id
        ${plan.withScore ? ", bm25(message_search, 1.0, 0.0)" : ", 0"}
        ${filtered ? ", c.space_id, g.space_id, g.is_archived" : ""}
      FROM message_search s
      JOIN message_search_doc d ON d.id = s.rowid
      ${filtered ? "LEFT JOIN chat c ON c.id = d.chat_id LEFT JOIN dialog g ON g.chat_id = d.chat_id" : ""}
      WHERE message_search MATCH ?
        ${plan.bound !== undefined ? `AND s.rowid ${comparator} ?` : ""}
      ORDER BY s.rowid ${plan.order === "desc" ? "DESC" : "ASC"}`
    const wantedSpace = plan.spaceId !== undefined ? String(plan.spaceId) : undefined
    const result = await this.store.readSearchIndex((db): ScanResult => {
      throwIfAborted(signal)
      const indexComplete = isComplete(readIndexState(db))
      const started = this.now()
      const candidates: Candidate[] = []
      let more = false
      let truncated = false
      let lastExamined: bigint | undefined
      let examined = 0
      const statement = db.prepare(sql)
      try {
        statement.bind(
          (plan.bound !== undefined ? [expression, plan.bound] : [expression]) as SqlValue[],
        )
        while (statement.step()) {
          const row = statement.get([]) as SqlValue[]
          const rowid = bigintOf(row[0])
          const chat = bigintOf(row[1])
          const message = bigintOf(row[2])
          examined += 1
          if (rowid === undefined || chat === undefined || message === undefined) continue
          if (candidates.length >= plan.take) {
            more = true
            break
          }
          lastExamined = rowid
          let accepted = true
          if (filtered) {
            const dialogSpace = row[5]
            const chatSpace = row[4]
            const space = dialogSpace ?? chatSpace
            if (wantedSpace !== undefined && (space == null || String(space) !== wantedSpace)) accepted = false
            if (!plan.includeArchived && Number(row[6] ?? 0) !== 0) accepted = false
          }
          if (accepted) {
            candidates.push({ rowid, chatId: chat, messageId: message, score: Number(row[3] ?? 0) })
          }
          if (
            examined >= this.maxScanned ||
            ((examined & 63) === 0 && this.now() - started > this.maxQueryMs)
          ) {
            truncated = true
            break
          }
        }
      } finally {
        statement.finalize()
      }
      const payloads = readPayloads(db, candidates)
      return {
        candidates,
        more,
        truncated,
        ...(lastExamined !== undefined ? { lastExamined } : {}),
        indexComplete,
        payloads,
      }
    })
    throwIfAborted(signal)
    return result
  }

  /**
   * Turn candidates into hits under read admission (invariant 13): a
   * message deleted or edited in memory after the disk read wins over the
   * row read, and its ranges are computed on the text the UI shows.
   */
  private async hydrate(
    candidates: readonly Candidate[],
    payloads: ReadonlyMap<string, Uint8Array>,
    parsed: ParsedQuery,
    signal: AbortSignal | undefined,
  ): Promise<MessageSearchHit[]> {
    const hits = await this.db.readThroughAdmission(
      async () => candidates,
      (rows, admission) => {
        const out: MessageSearchHit[] = []
        for (const candidate of rows) {
          const payload = payloads.get(keyOf(candidate.chatId, candidate.messageId))
          if (!payload) continue
          let stored: Message
          try {
            const model = decodeInlineModel(payload)
            if (model.kind !== DbObjectKind.Message) continue
            stored = model
          } catch {
            continue
          }
          const message = admission.reconcile(DbObjectKind.Message, stored)
          if (!message) continue
          const text = typeof message.message === "string" ? message.message : ""
          const ranges = matchRanges(text, parsed)
          if (!ranges) continue
          const snippet = messageSnippet(text, ranges)
          out.push({
            chatId: message.chatId,
            messageId: message.messageId,
            fromId: message.fromId,
            date: typeof message.date === "number" ? message.date : 0,
            out: message.out === true,
            text,
            ranges,
            snippet: snippet.snippet,
            snippetRanges: snippet.ranges,
            cursor: encodeRowid(candidate.rowid),
          })
        }
        return out
      },
    )
    throwIfAborted(signal)
    return hits
  }
}

const readPayloads = (db: Database, candidates: readonly Candidate[]): Map<string, Uint8Array> => {
  const payloads = new Map<string, Uint8Array>()
  if (candidates.length === 0) return payloads
  let statement: PreparedStatement | undefined
  try {
    statement = db.prepare("SELECT payload FROM message WHERE chat_id = ? AND message_id = ?")
    for (const candidate of candidates) {
      statement.bind([candidate.chatId, candidate.messageId] as SqlValue[])
      if (statement.step()) {
        const payload = statement.get(0)
        if (payload instanceof Uint8Array) {
          payloads.set(keyOf(candidate.chatId, candidate.messageId), payload)
        }
      }
      statement.reset()
      statement.clearBindings()
    }
  } finally {
    statement?.finalize()
  }
  return payloads
}

/**
 * The engine for a `Db` whose store can serve search (the SQLite replica),
 * or undefined (memory-only cores have no index).
 */
export const createMessageSearch = (
  db: Db,
  options: Omit<MessageSearchOptions, "db" | "store"> = {},
): MessageSearch | undefined => {
  const store = db.persistence
  if (!isMessageSearchStore(store)) return undefined
  return new MessageSearch({ ...options, db, store })
}
