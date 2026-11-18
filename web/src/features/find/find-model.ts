/**
 * Find in chat: the model behind the find bar of one chat pane. A port of
 * the Mac's `InChatSearchViewModel` and `InChatSearchBarState`
 * (`apple/InlineKit/Sources/InlineSearch/InChatSearchViewModel.swift`,
 * `apple/InlineMac/Features/Chat/InChatSearch/InChatSearchBar.swift`).
 *
 * - Matches are newest first, paged (100 per page) from a `FindInChatSource`.
 *   The first page is asked for 120 ms after the last change of the query
 *   (Mac `localDebounce`), together with the count ("3 of 128").
 * - A new query aborts everything in flight; an answer for an older query
 *   is dropped even if its source ignored the abort. While the new query's
 *   first page loads, the previous query's matches stay listed (no empty
 *   flash) but cannot be stepped to.
 * - Two presentations, as on the Mac: the list of previews (shown while the
 *   query changes) and "in the chat". While the list shows, moving through
 *   it does not scroll the chat; hiding the list jumps to the chosen match.
 *   Stepping with next or previous (Enter, Shift+Enter, Mod+G, Mod+Shift+G,
 *   the buttons) hides the list and jumps.
 * - Next is the next older match, previous the next newer one. No wrap-around
 *   (Mac: Find Next is disabled at the oldest match, Find Previous at the
 *   newest). A step past the loaded matches waits for the next page.
 * - Until the user moves, the current match follows the newest match as
 *   pages arrive.
 * - With a `server` source, the server's matches in the chat (350 ms after
 *   the last change, Mac `remoteDebounce`) are merged in by message ID, for
 *   history the device does not hold. The device's copy of a match wins.
 *   The current match is kept by message ID, so it stays current when
 *   server pages grow the list. A step to an older match waits for a
 *   source whose loaded matches stop above it (Mac `resolvePendingStep`),
 *   except the server's first page: a local match never waits for it.
 *   A server failure is quiet: local matches stay, `serverFailed` is set.
 *
 * Framework-free and DOM-free. Time goes through the injected clock; the
 * jump and the focus restore are injected callbacks.
 */

import type { ChatID, MessageID } from "@inline/ids"
import { batch, computed, signal, type Clock, type ReadSignal } from "@inline/reactive"
import { isMessageSearchable } from "@inline/view/quick-search"
import { isAbortError } from "../quick-search/core-sources"
import type { FindCount, FindInChatHit, FindInChatSource, FindPage, FindServerPage, FindServerSource, SearchRange } from "./find-source"

export const findTiming = {
  /** Mac `InChatSearchTiming.localDebounce`. */
  debounceMs: 120,
  /** Mac `InChatMessageSearch.pageLimit`; the core's maximum. */
  pageLimit: 100,
  /** Mac `InChatSearchViewModel.prefetchDistance`: the list loads the next page this close to its end. */
  prefetchDistance: 10,
  /** Empty pages (a source's work cap) followed before giving up on finding a first match. */
  maxEmptyPages: 20,
  /** Mac `InChatSearchTiming.remoteDebounce`: the server's first page and count. */
  serverDebounceMs: 350,
} as const

export type FindTiming = { -readonly [K in keyof typeof findTiming]: number }

/**
 * - `idle`: the field is empty, or the query has fewer than two letters or
 *   digits (the Mac's rule for local search).
 * - `searching`: waiting for the debounce or the first page (the previous
 *   query's matches may still be listed).
 * - `results`: at least one match.
 * - `noResults`: nothing matched in a complete index.
 * - `indexIncomplete`: nothing matched, but the index is still being built.
 * - `error`: the first page failed (`retry()`).
 */
export type FindState = "idle" | "searching" | "results" | "noResults" | "indexIncomplete" | "error"

/**
 * One match: message, sender, date, text and the matched ranges in it. A
 * local hit carries its index `cursor`; a server hit carries `remote` (the
 * device may not hold the message; the jump opens the chat around it).
 */
export type FindHit = Omit<FindInChatHit, "cursor"> & { readonly cursor?: string; readonly remote?: true }

/** Message IDs are canonical positive decimals: compare by length, then text. */
const compareIds = (a: MessageID, b: MessageID): number =>
  a.length !== b.length ? a.length - b.length : a < b ? -1 : a > b ? 1 : 0

const newestFirst = (a: FindHit, b: FindHit): number => compareIds(b.messageId, a.messageId)

const sameList = (a: readonly FindHit[], b: readonly FindHit[]): boolean =>
  a.length === b.length && a.every((hit, index) => hit === b[index])

/** What the chat is asked to show: the message, and the ranges of its text to highlight. */
export type FindJump = {
  readonly chatId: ChatID
  readonly messageId: MessageID
  /** `[start, end)` UTF-16 offsets into the message's text (`hit.text`). */
  readonly ranges: readonly SearchRange[]
  readonly query: string
}

export type FindPosition = {
  /** 1-based. */
  readonly index: number
  readonly total: number
  /** The total is a lower bound (the count was capped). */
  readonly capped: boolean
}

export type FindModelOptions = {
  readonly chatId: ChatID
  readonly source: FindInChatSource
  /**
   * The server's search in this chat (`coreServerFindSource(client)`), for
   * history the device does not hold. Optional: without it, find covers
   * what the device has indexed.
   */
  readonly server?: FindServerSource
  readonly clock: Pick<Clock, "setTimeout" | "clearTimeout">
  /**
   * Show a match in the chat. The chat pane passes the timeline
   * controller's `jumpToMessage(messageId)` (which flashes the row) and
   * hands the ranges to the row for a persistent highlight.
   */
  readonly jump: (target: FindJump) => void
  /**
   * Called when the bar opens; returns how to put focus back where it was
   * when it closes (the Mac falls back to the composer). Undefined: nothing
   * to restore.
   */
  readonly captureFocus?: () => (() => void) | undefined
  /** Called after the bar closed. */
  readonly onClose?: () => void
  readonly timing?: Partial<FindTiming>
}

type Phase = "idle" | "waiting" | "loading" | "done" | "error"

const numberFormat = new Intl.NumberFormat("en-US")
const formatCount = (count: number, capped: boolean) => `${numberFormat.format(count)}${capped ? "+" : ""}`

/** Line breaks, including the Unicode line and paragraph separators. */
const lineBreak = new RegExp(`\\r\\n|[\\r\\n${String.fromCharCode(0x2028, 0x2029)}]`)

/** A selection to seed the query with: its first line, trimmed, at most 128 characters. Undefined when empty. */
export const selectionSeed = (text: string | undefined | null): string | undefined => {
  if (typeof text !== "string") return undefined
  const line = (text.split(lineBreak)[0] ?? "").replace(/\s+/g, " ").trim()
  if (line.length === 0) return undefined
  if (line.length <= 128) return line
  // Do not cut a surrogate pair.
  const code = line.charCodeAt(127)
  return line.slice(0, code >= 0xd800 && code <= 0xdbff ? 127 : 128).trim()
}

export class FindInChatModel {
  readonly chatId: ChatID
  readonly #options: FindModelOptions
  readonly #timing: FindTiming

  readonly #open = signal(false)
  readonly #text = signal("")
  readonly #query = signal("")
  readonly #hits = signal<readonly FindHit[]>([])
  /** `#hits` still holds the previous query's matches. */
  readonly #stale = signal(false)
  readonly #phase = signal<Phase>("idle")
  readonly #pageLoading = signal(false)
  readonly #pageError = signal(false)
  readonly #hasOlder = signal(false)
  readonly #indexComplete = signal(true)
  readonly #count = signal<FindCount | undefined>(undefined)
  readonly #currentId = signal<MessageID | undefined>(undefined)
  readonly #showsResults = signal(false)
  readonly #fieldFocused = signal(false)
  readonly #focusRequest = signal(0)
  /** The server source may have more (older) matches. */
  readonly #serverMore = signal(false)
  /** The server's first page has not answered yet. */
  readonly #serverPending = signal(false)
  readonly #serverLoading = signal(false)
  readonly #serverFailed = signal(false)
  readonly #serverCount = signal<number | undefined>(undefined)

  /** This query's local matches, in the source's order (newest first). */
  #local: readonly FindHit[] = []
  /** This query's server matches by message ID. */
  readonly #serverHits = new Map<MessageID, FindHit>()
  #serverOffset: MessageID | undefined
  #serverTimer: unknown
  #serverTimerSet = false
  #cursor: string | undefined
  #generation = 0
  #abort: AbortController | undefined
  #timer: unknown
  #timerSet = false
  #pendingStep = false
  #pendingJump: FindHit | undefined
  #userNavigated = false
  #emptyPages = 0
  #restoreFocus: (() => void) | undefined
  #disposed = false

  /** Whether the bar is shown. */
  readonly isOpen: ReadSignal<boolean> = this.#open
  /** The field's text as typed. */
  readonly text: ReadSignal<string> = this.#text
  /** The trimmed query the matches are for. */
  readonly query: ReadSignal<string> = this.#query
  /** Matches loaded so far, newest first. Holds the previous query's matches until the new query's first page. */
  readonly hits: ReadSignal<readonly FindHit[]> = this.#hits
  /** Whether `hits` belongs to an earlier query (shown, never stepped to). */
  readonly stale: ReadSignal<boolean> = this.#stale
  readonly state: ReadSignal<FindState>
  /** The core's count for the query, capped as the core caps it. Undefined until it arrives. */
  readonly count: ReadSignal<FindCount | undefined> = this.#count
  /** The total to show: the count, never less than what is loaded. */
  readonly total: ReadSignal<{ readonly count: number; readonly capped: boolean } | undefined>
  readonly current: ReadSignal<FindHit | undefined>
  readonly currentIndex: ReadSignal<number | undefined>
  /** "3 of 128": the current match's position. */
  readonly position: ReadSignal<FindPosition | undefined>
  /** The text beside the field: "3 of 128", "128 messages" (while the list shows), "No results". */
  readonly counterText: ReadSignal<string | undefined>
  /** The previews list is shown under the field. */
  readonly showsResults: ReadSignal<boolean> = this.#showsResults
  /** A next page (local, or the server's after its first) is loading after the first one (the list's footer). */
  readonly loadingMore: ReadSignal<boolean>
  /** A later page failed; the loaded matches stay. `retry()` asks again. */
  readonly pagingFailed: ReadSignal<boolean> = this.#pageError
  /** More matches may exist older than the last loaded one (on the device or the server). */
  readonly hasOlder: ReadSignal<boolean>
  /** The server search failed (offline, refused); local matches stay. `retry()` asks again. */
  readonly serverFailed: ReadSignal<boolean> = this.#serverFailed
  /** A server page is pending (the first one, or a later one). */
  readonly serverSearching: ReadSignal<boolean>
  /** The server's exact count of matches in the chat, when the server source counts. */
  readonly serverCount: ReadSignal<number | undefined> = this.#serverCount
  /** False while the device's index is still being built: older matches may be missing. */
  readonly indexComplete: ReadSignal<boolean> = this.#indexComplete
  readonly canGoOlder: ReadSignal<boolean>
  readonly canGoNewer: ReadSignal<boolean>
  /** The bar's field has focus (the view reports it). Commands use it to let a second Mod+F reach the browser. */
  readonly fieldFocused: ReadSignal<boolean> = this.#fieldFocused
  /** Increments when the field should take focus (open, or Mod+F while open). */
  readonly focusRequest: ReadSignal<number> = this.#focusRequest

  readonly #indexById: ReadSignal<ReadonlyMap<MessageID, number>>

  constructor(options: FindModelOptions) {
    this.chatId = options.chatId
    this.#options = options
    this.#timing = { ...findTiming, ...options.timing }

    this.#indexById = computed(() => {
      const map = new Map<MessageID, number>()
      this.#hits.get().forEach((hit, index) => map.set(hit.messageId, index))
      return map
    })
    this.currentIndex = computed(() => {
      const id = this.#currentId.get()
      if (id === undefined || this.#stale.get()) return undefined
      return this.#indexById.get().get(id)
    })
    this.current = computed(() => {
      const index = this.currentIndex.get()
      return index === undefined ? undefined : this.#hits.get()[index]
    })
    this.hasOlder = computed(() => this.#hasOlder.get() || this.#serverMore.get())
    this.serverSearching = computed(() => this.#serverPending.get() || this.#serverLoading.get())
    this.state = computed<FindState>(() => {
      const phase = this.#phase.get()
      if (phase === "idle") return "idle"
      const hits = this.#hits.get()
      if (hits.length > 0 && !this.#stale.get()) return "results"
      if (phase === "error") return "error"
      if (phase === "waiting" || phase === "loading" || this.#pageLoading.get() || this.#stale.get() || this.#serverPending.get()) {
        return "searching"
      }
      return this.#indexComplete.get() ? "noResults" : "indexIncomplete"
    })
    this.total = computed(() => {
      if (this.#stale.get() || this.#phase.get() === "idle") return undefined
      const loaded = this.#hits.get().length
      const local = this.#count.get()
      const server = this.#serverCount.get()
      // The server's count is exact for the whole chat; the local one may be capped or miss history.
      const count = server !== undefined && (!local || server >= local.count) ? { count: server, capped: false } : local
      if (!count) return loaded > 0 ? { count: loaded, capped: false } : undefined
      return count.count >= loaded ? { count: count.count, capped: count.capped } : { count: loaded, capped: false }
    })
    this.position = computed(() => {
      const index = this.currentIndex.get()
      const total = this.total.get()
      if (index === undefined || !total) return undefined
      return { index: index + 1, total: total.count, capped: total.capped }
    })
    this.counterText = computed(() => {
      const state = this.state.get()
      if (state === "idle" || state === "searching") return undefined
      if (state !== "results") return state === "error" ? undefined : "No results"
      const total = this.total.get()
      if (!total) return undefined
      const position = this.position.get()
      if (position && !this.#showsResults.get()) return `${numberFormat.format(position.index)} of ${formatCount(total.count, total.capped)}`
      return total.count === 1 && !total.capped ? "1 message" : `${formatCount(total.count, total.capped)} messages`
    })
    this.loadingMore = computed(
      () =>
        (this.#pageLoading.get() || (this.#serverLoading.get() && !this.#serverPending.get())) &&
        this.#phase.get() === "done" &&
        this.#hits.get().length > 0,
    )
    this.canGoOlder = computed(() => {
      if (this.#stale.get()) return false
      const length = this.#hits.get().length
      if (length === 0) return false
      const index = this.currentIndex.get()
      return (
        index === undefined ||
        index < length - 1 ||
        (this.#hasOlder.get() && !this.#pageError.get()) ||
        (this.#serverMore.get() && !this.#serverFailed.get())
      )
    })
    this.canGoNewer = computed(() => {
      const index = this.currentIndex.get()
      return index !== undefined && index > 0
    })
  }

  // -------------------------------------------------------------------------
  // Opening and closing

  /**
   * Open the bar, or focus its field when it is open. `seed` (from the
   * page's text selection, see `selectionSeed`) replaces the query.
   */
  open(options: { readonly seed?: string } = {}): void {
    if (this.#disposed) return
    const seed = selectionSeed(options.seed)
    batch(() => {
      if (!this.#open.peek()) {
        this.#restoreFocus = this.#options.captureFocus?.()
        this.#open.set(true)
      }
      if (seed !== undefined) this.setText(seed)
      this.#focusRequest.set(this.#focusRequest.peek() + 1)
    })
  }

  /** Close the bar: cancel everything, clear the query, and put focus back where it was. */
  close(): void {
    if (!this.#open.peek()) return
    batch(() => {
      this.#text.set("")
      this.#query.set("")
      this.#restart()
      this.#fieldFocused.set(false)
      this.#open.set(false)
    })
    const restore = this.#restoreFocus
    this.#restoreFocus = undefined
    restore?.()
    this.#options.onClose?.()
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#cancel()
    this.#restoreFocus = undefined
    batch(() => {
      this.#open.set(false)
      this.#fieldFocused.set(false)
    })
  }

  // -------------------------------------------------------------------------
  // Query

  /** The field changed. Spaces at either end do not change the query or its results. */
  setText(text: string): void {
    if (this.#disposed) return
    const value = typeof text === "string" ? text : ""
    batch(() => {
      this.#text.set(value)
      const query = value.trim()
      if (query === this.#query.peek()) return
      this.#query.set(query)
      this.#restart()
    })
  }

  /** Ask again after a failure, keeping what is loaded. */
  retry(): void {
    if (this.#disposed || !this.#open.peek()) return
    if (this.#serverFailed.peek() && this.#options.server) {
      batch(() => {
        this.#serverFailed.set(false)
        this.#serverMore.set(true)
      })
      this.#loadServerPage(this.#generation)
    }
    if (this.#phase.peek() === "error") {
      batch(() => {
        this.#phase.set("loading")
        this.#emptyPages = 0
      })
      const generation = this.#generation
      this.#loadPage(generation)
      if (!this.#count.peek()) this.#loadCount(generation)
      return
    }
    if (this.#pageError.peek()) {
      this.#pageError.set(false)
      this.#loadPage(this.#generation)
    }
  }

  setFieldFocused(focused: boolean): void {
    this.#fieldFocused.set(focused && this.#open.peek())
  }

  // -------------------------------------------------------------------------
  // Navigation

  /** The next older match; hides the list and shows it in the chat (Enter over the chat, Mod+G). */
  next(): void {
    if (!this.#searchable()) return
    this.#stepOlder()
    this.setShowsResults(false)
  }

  /** The next newer match; hides the list and shows it in the chat (Shift+Enter, Mod+Shift+G). */
  previous(): void {
    if (!this.#searchable()) return
    this.#stepNewer()
    this.setShowsResults(false)
  }

  /**
   * Move through the list without leaving it (the arrows while the list
   * shows; newest is on top, so +1 is older). Over the chat, the view maps
   * the arrows to `next` and `previous` instead.
   */
  moveActive(delta: 1 | -1): void {
    if (!this.#searchable()) return
    if (delta > 0) this.#stepOlder()
    else this.#stepNewer()
  }

  /** Enter: over the list, show the chosen match in the chat; over the chat, the next match. */
  submit(): void {
    if (!this.#searchable()) return
    if (this.#showsResults.peek() && this.#hits.peek().length > 0 && !this.#stale.peek()) {
      if (this.currentIndex.peek() === undefined) {
        const newest = this.#hits.peek()[0]
        if (newest) this.#select(newest, true)
      }
      this.setShowsResults(false)
      return
    }
    this.next()
  }

  /** Choose a match (a click on a preview): it becomes current and the chat shows it. */
  activate(hit: FindHit): void {
    if (this.#disposed || this.#stale.peek()) return
    const index = this.#indexById.peek().get(hit.messageId)
    const current = index === undefined ? undefined : this.#hits.peek()[index]
    if (!current) return
    this.#pendingStep = false
    this.#select(current, true)
    this.setShowsResults(false)
  }

  /** Show or hide the previews. Hiding them shows the match chosen while they showed. */
  setShowsResults(shows: boolean): void {
    if (shows && !this.#searchable()) return
    if (shows === this.#showsResults.peek()) return
    this.#showsResults.set(shows)
    if (shows) return
    const pending = this.#pendingJump
    this.#pendingJump = undefined
    if (pending) this.#jump(pending)
  }

  toggleResults(): void {
    this.setShowsResults(!this.#showsResults.peek())
  }

  /** The list shows the row at `index`: load the next page when it is near the end. */
  loadMoreIfNeeded(index: number): void {
    if (this.#stale.peek() || this.#phase.peek() !== "done") return
    if (this.#hits.peek().length - index > this.#timing.prefetchDistance) return
    if (this.#hasOlder.peek() && !this.#pageError.peek()) this.#loadPage(this.#generation)
    if (this.#serverMore.peek() && !this.#serverFailed.peek() && !this.#serverPending.peek()) this.#loadServerPage(this.#generation)
  }

  // -------------------------------------------------------------------------
  // Internals

  #searchable(): boolean {
    return !this.#disposed && this.#open.peek() && isMessageSearchable(this.#query.peek())
  }

  #cancel(): void {
    this.#generation++
    this.#abort?.abort()
    this.#abort = undefined
    if (this.#timerSet) this.#options.clock.clearTimeout(this.#timer as never)
    this.#timerSet = false
    if (this.#serverTimerSet) this.#options.clock.clearTimeout(this.#serverTimer as never)
    this.#serverTimerSet = false
  }

  #restart(): void {
    this.#cancel()
    const generation = this.#generation
    this.#cursor = undefined
    this.#pendingStep = false
    this.#pendingJump = undefined
    this.#userNavigated = false
    this.#emptyPages = 0
    this.#local = []
    this.#serverHits.clear()
    this.#serverOffset = undefined
    const query = this.#query.peek()
    const server = this.#options.server !== undefined && this.#open.peek() && isMessageSearchable(query)
    batch(() => {
      this.#currentId.set(undefined)
      this.#count.set(undefined)
      this.#pageLoading.set(false)
      this.#pageError.set(false)
      this.#hasOlder.set(false)
      this.#indexComplete.set(true)
      this.#serverMore.set(server)
      this.#serverPending.set(server)
      this.#serverLoading.set(false)
      this.#serverFailed.set(false)
      this.#serverCount.set(undefined)
      if (!this.#open.peek() || !isMessageSearchable(query)) {
        this.#hits.set([])
        this.#stale.set(false)
        this.#phase.set("idle")
        this.#showsResults.set(false)
        return
      }
      this.#stale.set(this.#hits.peek().length > 0)
      this.#phase.set("waiting")
      // A new query shows its previews; the old query's chosen match is dropped, not jumped to.
      this.#showsResults.set(true)
    })
    if (this.#phase.peek() !== "waiting") return
    this.#timerSet = true
    this.#timer = this.#options.clock.setTimeout(() => {
      this.#timerSet = false
      if (generation !== this.#generation) return
      this.#phase.set("loading")
      this.#loadPage(generation)
      this.#loadCount(generation)
    }, this.#timing.debounceMs)
    if (!server) return
    this.#serverTimerSet = true
    this.#serverTimer = this.#options.clock.setTimeout(() => {
      this.#serverTimerSet = false
      if (generation !== this.#generation) return
      this.#loadServerPage(generation)
      this.#loadServerCount(generation)
    }, this.#timing.serverDebounceMs)
  }

  #signal(): AbortSignal {
    this.#abort ??= new AbortController()
    return this.#abort.signal
  }

  #loadPage(generation: number): void {
    if (generation !== this.#generation || this.#pageLoading.peek()) return
    this.#pageLoading.set(true)
    const request = {
      chatId: this.chatId,
      query: this.#query.peek(),
      ...(this.#cursor !== undefined ? { cursor: this.#cursor } : {}),
      limit: this.#timing.pageLimit,
    }
    let pending: Promise<FindPage>
    try {
      pending = this.#options.source.find(request, this.#signal())
    } catch (error) {
      pending = Promise.reject(error)
    }
    pending.then(
      (page) => {
        if (generation === this.#generation) this.#finishPage(page)
      },
      (error: unknown) => {
        if (generation !== this.#generation || isAbortError(error)) return
        this.#failPage()
      },
    )
  }

  #failPage(): void {
    this.#pendingStep = false
    batch(() => {
      this.#pageLoading.set(false)
      if (this.#phase.peek() === "done") {
        this.#pageError.set(true)
        return
      }
      this.#phase.set("error")
      this.#applyHits(false)
    })
    this.#resolvePendingStep()
  }

  #finishPage(page: FindPage): void {
    const previousCursor = this.#cursor
    const advanced = page.olderCursor !== undefined && page.olderCursor !== previousCursor
    this.#cursor = page.olderCursor ?? previousCursor
    let hasOlder = page.hasOlder && advanced
    const existing = this.#local
    const seen = new Set(existing.map((hit) => hit.messageId))
    const added = page.hits.filter((hit) => {
      if (seen.has(hit.messageId)) return false
      seen.add(hit.messageId)
      return true
    })
    this.#local = added.length > 0 ? [...existing, ...added] : existing
    let keepLooking = false
    if (this.#local.length === 0 && hasOlder) {
      // Nothing yet, but the source stopped early (a work cap): keep looking, a bounded number of pages.
      this.#emptyPages++
      if (this.#emptyPages <= this.#timing.maxEmptyPages) keepLooking = true
      else hasOlder = false
    }
    batch(() => {
      this.#pageLoading.set(false)
      this.#hasOlder.set(hasOlder)
      this.#indexComplete.set(page.indexComplete)
      if (!keepLooking) this.#phase.set("done")
      this.#applyHits(keepLooking)
    })
    if (keepLooking) {
      this.#loadPage(this.#generation)
      return
    }
    this.#afterHits()
  }

  /**
   * Install the merged matches. The previous query's matches stay listed
   * until this query has one or every source has answered (`keepStale` also
   * keeps them while a capped source is still being followed).
   */
  #applyHits(keepStale: boolean): void {
    const merged = this.#merged()
    const stale = this.#stale.peek()
    if (stale && merged.length === 0) {
      const phase = this.#phase.peek()
      const localLoading = phase === "waiting" || phase === "loading"
      if (keepStale || localLoading || this.#serverPending.peek()) return
    }
    batch(() => {
      if (stale || !sameList(merged, this.#hits.peek())) this.#hits.set(merged)
      this.#stale.set(false)
    })
    // A current match that is no longer listed is dropped.
    const current = this.#currentId.peek()
    if (current !== undefined && !this.#indexById.peek().has(current)) this.#currentId.set(undefined)
  }

  /** Local matches, then the server's that the device did not list, newest first by message ID. */
  #merged(): readonly FindHit[] {
    if (this.#serverHits.size === 0) return this.#local
    const byId = new Map<MessageID, FindHit>()
    for (const hit of this.#serverHits.values()) byId.set(hit.messageId, hit)
    for (const hit of this.#local) byId.set(hit.messageId, hit)
    return [...byId.values()].sort(newestFirst)
  }

  /** After new matches: follow the newest until the user moves; settle a waiting step. */
  #afterHits(): void {
    // Still the previous query's matches (this query has none yet): nothing to follow.
    if (this.#stale.peek()) return
    const hadSelection = this.#currentId.peek() !== undefined
    const hits = this.#hits.peek()
    // Until the user moves, the selection follows the newest match as pages arrive.
    const newest = hits[0]
    if (!this.#userNavigated && newest && newest.messageId !== this.#currentId.peek()) this.#select(newest, false)
    if (!hadSelection && this.#currentId.peek() !== undefined && this.#pendingStep) {
      // A step made before any match loaded lands on the newest match, not past it.
      this.#pendingStep = false
      this.#userNavigated = true
    }
    this.#resolvePendingStep()
  }

  #loadCount(generation: number): void {
    let pending: Promise<FindCount>
    try {
      pending = this.#options.source.count({ chatId: this.chatId, query: this.#query.peek() }, this.#signal())
    } catch (error) {
      pending = Promise.reject(error)
    }
    pending.then(
      (count) => {
        if (generation !== this.#generation) return
        this.#count.set({ count: count.count, capped: count.capped, indexComplete: count.indexComplete })
      },
      () => {
        // The count is a nicety: without it the total is what is loaded.
      },
    )
  }

  #loadServerPage(generation: number): void {
    const server = this.#options.server
    if (!server || generation !== this.#generation || this.#serverLoading.peek()) return
    if (!this.#serverMore.peek() || this.#serverFailed.peek()) return
    if (this.#serverTimerSet) {
      // A step that needs the server does not wait for the debounce.
      this.#options.clock.clearTimeout(this.#serverTimer as never)
      this.#serverTimerSet = false
      this.#loadServerCount(generation)
    }
    this.#serverLoading.set(true)
    const offsetId = this.#serverOffset
    const request = {
      chatId: this.chatId,
      query: this.#query.peek(),
      ...(offsetId !== undefined ? { offsetId } : {}),
      limit: this.#timing.pageLimit,
    }
    let pending: Promise<FindServerPage>
    try {
      pending = server.find(request, this.#signal())
    } catch (error) {
      pending = Promise.reject(error)
    }
    pending.then(
      (page) => {
        if (generation === this.#generation) this.#finishServerPage(page, offsetId)
      },
      (error: unknown) => {
        if (generation !== this.#generation || isAbortError(error)) return
        this.#failServer()
      },
    )
  }

  #finishServerPage(page: FindServerPage, requested: MessageID | undefined): void {
    for (const hit of page.hits) {
      if (!this.#serverHits.has(hit.messageId)) {
        this.#serverHits.set(hit.messageId, {
          messageId: hit.messageId,
          fromId: hit.fromId,
          date: hit.date,
          out: hit.out,
          text: hit.text,
          ranges: hit.ranges,
          remote: true,
        })
      }
    }
    // A cursor that does not move would ask for the same page forever.
    const advanced = page.nextOffsetId !== undefined && page.nextOffsetId !== requested
    this.#serverOffset = page.nextOffsetId ?? requested
    batch(() => {
      this.#serverLoading.set(false)
      this.#serverPending.set(false)
      this.#serverMore.set(advanced && page.hits.length > 0)
      this.#applyHits(false)
    })
    this.#afterHits()
  }

  #failServer(): void {
    batch(() => {
      this.#serverLoading.set(false)
      this.#serverPending.set(false)
      this.#serverMore.set(false)
      this.#serverFailed.set(true)
      this.#applyHits(false)
    })
    this.#resolvePendingStep()
  }

  #loadServerCount(generation: number): void {
    const count = this.#options.server?.count
    if (!count) return
    let pending: Promise<number>
    try {
      pending = count({ chatId: this.chatId, query: this.#query.peek() }, this.#signal())
    } catch (error) {
      pending = Promise.reject(error)
    }
    pending.then(
      (value) => {
        if (generation === this.#generation) this.#serverCount.set(value)
      },
      () => {
        // A nicety, like the local count.
      },
    )
  }

  #stepOlder(): void {
    this.#pendingStep = true
    this.#resolvePendingStep()
  }

  #stepNewer(): void {
    this.#pendingStep = false
    const index = this.currentIndex.peek()
    if (index === undefined || index <= 0) return
    const hit = this.#hits.peek()[index - 1]
    if (hit) this.#select(hit, true)
  }

  #resolvePendingStep(): void {
    // A step waits for the new query's matches rather than landing on an old one.
    if (!this.#pendingStep || this.#stale.peek()) return
    const hits = this.#hits.peek()
    const index = this.currentIndex.peek()
    if (index === undefined) {
      const newest = hits[0]
      if (newest) {
        this.#pendingStep = false
        this.#select(newest, true)
      } else if (this.#phase.peek() === "done" || this.#phase.peek() === "error") {
        if (!this.#localMore() && !this.#serverMoreUsable() && !this.#serverPending.peek()) this.#pendingStep = false
      }
      return
    }
    const older = hits[index + 1]
    // A source whose loaded matches stop above the candidate may still hold one between the two.
    const localBlocks = this.#localMore() && (older === undefined || this.#isAbove(this.#localFloor(), older.messageId))
    // The server's first page does not hold up a step to a local match: device matches show at once.
    const serverBlocks =
      this.#serverMoreUsable() &&
      (older === undefined || (!this.#serverPending.peek() && this.#isAbove(this.#serverOffset, older.messageId)))
    if (localBlocks || serverBlocks) {
      if (localBlocks) this.#loadPage(this.#generation)
      if (serverBlocks) this.#loadServerPage(this.#generation)
      return
    }
    this.#pendingStep = false
    // Without an older match, this is the oldest: no wrap-around.
    if (older) this.#select(older, true)
  }

  #localMore(): boolean {
    return this.#hasOlder.peek() && !this.#pageError.peek()
  }

  #serverMoreUsable(): boolean {
    return this.#serverMore.peek() && !this.#serverFailed.peek()
  }

  /** The oldest local match: every local match newer than it is loaded. */
  #localFloor(): MessageID | undefined {
    return this.#local[this.#local.length - 1]?.messageId
  }

  /** `floor` (undefined: nothing loaded yet, so above everything) is newer than `id`. */
  #isAbove(floor: MessageID | undefined, id: MessageID): boolean {
    return floor === undefined || compareIds(floor, id) > 0
  }

  #select(hit: FindHit, byUser: boolean): void {
    if (byUser) this.#userNavigated = true
    this.#currentId.set(hit.messageId)
    if (this.#showsResults.peek()) this.#pendingJump = hit
    else {
      this.#pendingJump = undefined
      this.#jump(hit)
    }
  }

  #jump(hit: FindHit): void {
    this.#options.jump({ chatId: this.chatId, messageId: hit.messageId, ranges: hit.ranges, query: this.#query.peek() })
  }
}
