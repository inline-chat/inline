/**
 * A stand-in core for the find lab: a `CoreEndpoint` that answers
 * `findInChat` and `countMessages` subscriptions over generated messages,
 * with a settable delay, an "indexing" mode (only the newer half of the
 * chat is findable, and answers say the index is incomplete), and failure
 * modes. It speaks the real protocol (patches with a `search` resource), so
 * the real store client, `coreFindSource` and the model run unchanged.
 *
 * It also answers `searchServerMessages` (a `remoteSearch` resource) as the
 * server would, over every message. Server modes: `off` (the device holds
 * the whole chat; the server finds the same matches, which merge away),
 * `older` (the device holds only the newest quarter; the server adds the
 * older history), `fail` (the device holds the newest quarter; the server
 * fails with `offline`).
 *
 * Matching is the lab's own (every query word must start a word of the
 * message, case-insensitive); the real index lives in the client package.
 */

import type {
  Command,
  CoreEndpoint,
  CoreMessageListener,
  FindInChatHit,
  QueryDescriptor,
  RemoteSearchResource,
  SearchRange,
  SearchResource,
  ServerMessageHit,
  SubId,
} from "@inline/core-protocol"
import type { MessageID, UserID } from "@inline/ids"

export type LabMessage = {
  readonly messageId: MessageID
  readonly fromId: UserID
  readonly out: boolean
  /** Seconds since the epoch. */
  readonly date: number
  readonly text: string
}

export type LabCoreMode = "ready" | "indexing" | "error" | "failPaging"

export type LabServerMode = "off" | "older" | "fail"

export type LabCoreSettings = {
  /** How long an answer takes (the server takes twice as long). */
  delayMs: number
  mode: LabCoreMode
  server: LabServerMode
}

export type LabCoreStats = {
  find: number
  count: number
  /** `searchServerMessages` requests (pages and counts). */
  server: number
  answered: number
  cancelled: number
  failed: number
}

const words = [
  "deploy", "the", "release", "build", "review", "notes", "server", "client", "design", "meeting",
  "tomorrow", "launch", "fix", "bug", "ship", "plan", "draft", "update", "search", "index",
  "timeline", "message", "thread", "agent", "status", "check", "merge", "branch", "test", "green",
]
const rtlLines = ["سلام دنیا، استقرار امروز انجام شد", "بررسی پیام‌ها و جستجو", "שלום, ה-deploy עבר בהצלחה"]
const emoji = ["🚀", "👍🏽", "✅", "🔥"]

/** A small deterministic PRNG (mulberry32). */
const prng = (seed: number) => {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

export const LAB_ME = "1" as UserID

/** `count` messages, oldest first; "deploy" appears in about two thirds of them. */
export const generateMessages = (count: number, seed = 7): LabMessage[] => {
  const random = prng(seed)
  const pick = <T>(list: readonly T[]): T => list[Math.floor(random() * list.length)] as T
  const start = Math.floor(Date.UTC(2026, 0, 5, 9) / 1000)
  const messages: LabMessage[] = []
  let date = start
  for (let i = 1; i <= count; i++) {
    date += 30 + Math.floor(random() * 3600 * 3)
    const length = 3 + Math.floor(random() * 22)
    const parts: string[] = []
    for (let w = 0; w < length; w++) parts.push(pick(words))
    if (random() < 0.5) parts.splice(Math.floor(random() * parts.length), 0, "deploy")
    if (random() < 0.08) parts.push(pick(emoji))
    let text = parts.join(" ")
    text = text.charAt(0).toUpperCase() + text.slice(1)
    if (random() < 0.05) text = pick(rtlLines)
    if (random() < 0.05) text = `${text}\n\n${parts.slice(0, 5).join(" ")}`
    const fromId = String(1 + Math.floor(random() * 5)) as UserID
    messages.push({ messageId: String(i) as MessageID, fromId, out: fromId === LAB_ME, date, text })
  }
  return messages
}

const wordStart = /[\p{L}\p{N}\p{Extended_Pictographic}]+/gu

/** Ranges of every word of `text` that starts with a query word; undefined unless every query word matched. */
export const labMatch = (text: string, query: string): SearchRange[] | undefined => {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return undefined
  const lower = text.toLowerCase()
  const ranges: SearchRange[] = []
  const matched = new Set<string>()
  for (const match of lower.matchAll(wordStart)) {
    const word = match[0]
    const at = match.index ?? 0
    for (const term of terms) {
      if (word.startsWith(term)) {
        ranges.push([at, at + term.length])
        matched.add(term)
      }
    }
  }
  return terms.every((term) => matched.has(term)) ? ranges : undefined
}

type Timer = ReturnType<typeof setTimeout>

export class LabCore implements CoreEndpoint {
  readonly messages: readonly LabMessage[]
  settings: LabCoreSettings = { delayMs: 150, mode: "ready", server: "off" }
  readonly stats: LabCoreStats = { find: 0, count: 0, server: 0, answered: 0, cancelled: 0, failed: 0 }
  readonly #listeners = new Set<CoreMessageListener>()
  readonly #timers = new Map<SubId, Timer>()
  #revision = 0
  #closed = false

  constructor(messages: readonly LabMessage[]) {
    this.messages = messages
  }

  /** Requests waiting for their answer. */
  pending(): number {
    return this.#timers.size
  }

  post(command: Command): void {
    if (this.#closed) return
    if (command.kind === "subscribe") this.#subscribe(command.sub, command.query)
    else if (command.kind === "unsubscribe") {
      const timer = this.#timers.get(command.sub)
      if (timer !== undefined) {
        clearTimeout(timer)
        this.#timers.delete(command.sub)
        this.stats.cancelled++
      }
    }
  }

  subscribe(listener: CoreMessageListener): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  close(): void {
    this.#closed = true
    for (const timer of this.#timers.values()) clearTimeout(timer)
    this.#timers.clear()
    this.#listeners.clear()
  }

  #deliver(sub: SubId, value: SearchResource | RemoteSearchResource): void {
    const base = this.#revision
    this.#revision = base + 1
    const message = {
      kind: "patch" as const,
      patch: { base, revision: base + 1, rows: [], lists: [], resources: [{ sub, value }], settled: [] },
    }
    for (const listener of this.#listeners) listener(message)
  }

  #subscribe(sub: SubId, query: QueryDescriptor): void {
    if (query.kind !== "findInChat" && query.kind !== "countMessages" && query.kind !== "searchServerMessages") return
    if (query.kind === "findInChat") this.stats.find++
    else if (query.kind === "countMessages") this.stats.count++
    else this.stats.server++
    const remote = query.kind === "searchServerMessages"
    queueMicrotask(() => {
      if (this.#timers.has(sub)) this.#deliver(sub, remote ? { kind: "remoteSearch", status: "pending" } : { kind: "search", status: "pending" })
    })
    const timer = setTimeout(
      () => {
        this.#timers.delete(sub)
        const value = query.kind === "searchServerMessages" ? this.#answerServer(query.request) : this.#answer(query)
        if (value.status === "failed") this.stats.failed++
        else this.stats.answered++
        this.#deliver(sub, value)
      },
      Math.max(0, this.settings.delayMs) * (remote ? 2 : 1),
    )
    this.#timers.set(sub, timer)
  }

  /** Messages on the device: all, or the newest quarter when the server holds older history. */
  #onDevice(): readonly LabMessage[] {
    return this.settings.server === "off" ? this.messages : this.messages.slice(Math.floor((this.messages.length * 3) / 4))
  }

  /** Messages the index has: those on the device, or the newer half of them while "indexing". */
  #indexed(): readonly LabMessage[] {
    const device = this.#onDevice()
    return this.settings.mode === "indexing" ? device.slice(Math.floor(device.length / 2)) : device
  }

  #answerServer(request: Extract<QueryDescriptor, { kind: "searchServerMessages" }>["request"]): RemoteSearchResource {
    if (this.settings.server === "fail") return { kind: "remoteSearch", status: "failed", reason: "offline" }
    if (request.countOnly) {
      let count = 0
      for (const message of this.messages) if (labMatch(message.text, request.query)) count++
      return { kind: "remoteSearch", status: "done", result: { kind: "count", chatId: request.chatId, count } }
    }
    const before = request.offsetId !== undefined ? Number(request.offsetId) : Number.POSITIVE_INFINITY
    const limit = Math.max(1, Math.min(100, request.limit ?? 50))
    const hits: ServerMessageHit[] = []
    let more = false
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const message = this.messages[i] as LabMessage
      if (Number(message.messageId) >= before) continue
      const ranges = labMatch(message.text, request.query)
      if (!ranges) continue
      if (hits.length === limit) {
        more = true
        break
      }
      hits.push({ messageId: message.messageId, fromId: message.fromId, date: message.date, out: message.out, text: message.text, ranges })
    }
    const last = hits[hits.length - 1]
    return {
      kind: "remoteSearch",
      status: "done",
      result: { kind: "messages", chatId: request.chatId, hits, ...(more && last ? { nextOffsetId: last.messageId } : {}) },
    }
  }

  #answer(query: QueryDescriptor): SearchResource {
    const mode = this.settings.mode
    const indexComplete = mode !== "indexing"
    if (query.kind === "countMessages") {
      if (mode === "error") return { kind: "search", status: "failed", reason: "storage" }
      let count = 0
      for (const message of this.#indexed()) if (labMatch(message.text, query.request.query)) count++
      return { kind: "search", status: "done", result: { kind: "count", count: Math.min(count, 10_000), capped: count > 10_000, indexComplete } }
    }
    if (query.kind !== "findInChat") return { kind: "search", status: "failed", reason: "invalid" }
    const request = query.request
    if (mode === "error" || (mode === "failPaging" && request.cursor !== undefined)) {
      return { kind: "search", status: "failed", reason: "storage" }
    }
    const before = request.cursor !== undefined ? Number(request.cursor) : Number.POSITIVE_INFINITY
    const limit = Math.max(1, Math.min(100, request.limit ?? 100))
    const indexed = this.#indexed()
    const hits: FindInChatHit[] = []
    let hasOlder = false
    for (let i = indexed.length - 1; i >= 0; i--) {
      const message = indexed[i] as LabMessage
      if (Number(message.messageId) >= before) continue
      const ranges = labMatch(message.text, request.query)
      if (!ranges) continue
      if (hits.length === limit) {
        hasOlder = true
        break
      }
      hits.push({
        messageId: message.messageId,
        fromId: message.fromId,
        date: message.date,
        out: message.out,
        text: message.text,
        ranges,
        cursor: message.messageId,
      })
    }
    const last = hits[hits.length - 1]
    return {
      kind: "search",
      status: "done",
      result: {
        kind: "findInChat",
        hits,
        hasOlder,
        hasNewer: false,
        ...(hasOlder && last ? { olderCursor: last.cursor } : {}),
        indexComplete,
        truncated: false,
      },
    }
  }
}
