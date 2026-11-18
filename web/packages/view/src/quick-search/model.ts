/**
 * The Quick Search model (Cmd/Ctrl+K): one query, sections of results, an
 * active item, keyboard navigation and activation. Framework-free; a view
 * renders `sections`, highlights `activeId` and forwards keys.
 *
 * The behavior is the Mac app's `QuickSearchViewModel`
 * (apple/InlineMac/Features/CommandBar/QuickSearchPopover.swift), with one
 * product rule made strict: results already shown never move. Local results
 * are computed synchronously from the query; local message search runs after
 * a 120 ms debounce; the server is asked after 250 ms. Async sections append
 * below what is shown, in the order they arrive.
 */

import type { UserRow } from "@inline/core-protocol"
import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"
import { batch, computed, signal, type Clock, type ReadSignal } from "@inline/reactive"
import type { Command, CommandRegistry } from "../commands/registry"
import type { Destination } from "../workspace/destination"
import type { OpenIntent } from "../workspace/workspace"
import { compareMatches, matchField, matchFields, prepareFields, prepareQuery, type Match, type MatchRange, type PreparedField, type PreparedQuery } from "./match"
import {
  fieldPriority,
  isMessageSearchable,
  remoteUserFields,
  userUsageKey,
  chatUsageKey,
  type ChatCandidate,
  type MessageHit,
  type SpaceCandidate,
  type UserCandidate,
  type QuickSearchLocalSource,
  type QuickSearchMessageSource,
  type QuickSearchRemoteSource,
} from "./sources"
import { compareByMatch, compareRanked, compareSuggestions, noUsage, rankScore, type UsageSignal, type UsageStore } from "./usage"
import { userDisplayName } from "@inline/chat-ui"

// ---------------------------------------------------------------------------
// Constants

/** Timing, from `QuickSearchViewModel.searchMessages` and `searchGlobalUsers`. */
export const quickSearchTiming = {
  /** Local message search waits this long after the last keystroke. */
  messageDebounceMs: 120,
  /** The server is asked this long after the last keystroke. */
  remoteDelayMs: 250,
} as const

/** Limits, from `runLocalProjection`, `projectSpaces`, `messageSearchOptions` and `rankGlobalUsers`. */
export const quickSearchLimits = {
  suggestions: 5,
  /** Chats listed under an empty query. */
  emptyQueryChats: 5,
  chats: 20,
  spaces: 10,
  messages: 20,
  global: 20,
} as const

export type QuickSearchSectionKind = "suggestions" | "chats" | "spaces" | "commands" | "messages" | "global"

export const quickSearchSectionTitles: Readonly<Record<QuickSearchSectionKind, string>> = {
  suggestions: "Suggestions",
  chats: "Chats",
  spaces: "Spaces",
  commands: "Commands",
  messages: "Messages",
  global: "Global Search",
}

// ---------------------------------------------------------------------------
// Items

type ItemBase = {
  /** Stable for the same thing across queries and updates; unique in the list. */
  readonly id: string
  readonly section: QuickSearchSectionKind
  readonly title: string
  readonly subtitle?: string
  /** Ranges of `title` to highlight (UTF-16). Empty when the match was in another field. */
  readonly titleRanges: readonly MatchRange[]
}

export type QuickSearchChatItem = ItemBase & {
  readonly kind: "chat"
  readonly chatId: ChatID
  readonly peerUserId?: UserID
  readonly spaceId?: SpaceID
  readonly emoji?: string
  readonly unread: boolean
}

export type QuickSearchUserItem = ItemBase & {
  readonly kind: "user"
  readonly userId: UserID
  /** From the server: the account has no chat with this person yet. */
  readonly remote: boolean
  readonly user?: UserRow
}

export type QuickSearchSpaceItem = ItemBase & { readonly kind: "space"; readonly spaceId: SpaceID }

export type QuickSearchCommandItem = ItemBase & {
  readonly kind: "command"
  readonly commandId: string
  readonly category: Command["category"]
}

/** `Create "<title>"`: a new thread in the current space titled with the query. */
export type QuickSearchCreateItem = ItemBase & {
  readonly kind: "createThread"
  readonly spaceId: SpaceID
  /** The thread title: the trimmed query. `title` is the row label. */
  readonly threadTitle: string
}

export type QuickSearchMessageItem = ItemBase & {
  readonly kind: "message"
  readonly chatId: ChatID
  readonly messageId: MessageID
  readonly peerUserId?: UserID
  /** Seconds since the epoch. */
  readonly date: number
  readonly snippet: string
  readonly snippetRanges: readonly MatchRange[]
  /** From the server's search rather than the local index. */
  readonly remote: boolean
}

export type QuickSearchItem =
  | QuickSearchChatItem
  | QuickSearchUserItem
  | QuickSearchSpaceItem
  | QuickSearchCommandItem
  | QuickSearchCreateItem
  | QuickSearchMessageItem

export type QuickSearchSection = {
  readonly kind: QuickSearchSectionKind
  readonly title: string
  readonly items: readonly QuickSearchItem[]
}

/** `pending` covers both the debounce and the request in flight. */
export type AsyncStatus = "idle" | "pending" | "done" | "error"

export type AsyncSectionState = { readonly status: AsyncStatus; readonly error?: unknown }

/** What the list area shows when it has no rows, as the Mac view decides. */
export type QuickSearchEmptyState = "results" | "loading" | "error" | "noResults" | "blank"

/** What activating an item asks the app to do. The model has already recorded usage and closed. */
export type QuickSearchOutcome =
  | { readonly kind: "open"; readonly destination: Destination; readonly intent: OpenIntent }
  /** Open the direct chat with this person, creating it if needed (the Mac's `openChat(peer: .user)`). */
  | { readonly kind: "openUser"; readonly userId: UserID; readonly intent: OpenIntent }
  /** Select the space in the sidebar (the Mac's `openSpace`). */
  | { readonly kind: "openSpace"; readonly spaceId: SpaceID }
  /** Run through the registry: `registry.run(commandId, { source: "palette" })`, after focus is restored. */
  | { readonly kind: "runCommand"; readonly commandId: string }
  | { readonly kind: "createThread"; readonly spaceId: SpaceID; readonly title: string }
  /** Nothing to do: no item, or an item from an older list. */
  | { readonly kind: "none" }

/** Where the user is. Read when ranking (current space first) and for the Create row. */
export type QuickSearchContext = {
  /** The selected space; enables the Create row and scopes message search, as on the Mac. */
  readonly spaceId?: SpaceID
}

export type QuickSearchOptions = {
  /** Timers. Use `manualTime()` in tests. */
  readonly clock: Pick<Clock, "setTimeout" | "clearTimeout">
  /** Wall time in milliseconds since the epoch, for usage decay. Defaults to `Date.now`. */
  readonly now?: () => number
  readonly local?: QuickSearchLocalSource
  readonly commands?: CommandRegistry
  /** Extra words a command is found by (the Mac's `keywords`). */
  readonly commandKeywords?: (command: Command) => readonly string[]
  /** Commands never listed. Defaults to `app.quickSearch`. */
  readonly excludeCommands?: readonly string[]
  readonly messages?: QuickSearchMessageSource
  readonly remote?: QuickSearchRemoteSource
  readonly usage?: UsageStore
  readonly context?: ReadSignal<QuickSearchContext>
  readonly timing?: Partial<Record<keyof typeof quickSearchTiming, number>>
}

// ---------------------------------------------------------------------------
// Helpers

const lineBreaks = /[\r\n\u2028\u2029]+/g
const singleLine = (value: string): string => (typeof value === "string" ? value.replace(lineBreaks, " ") : "")

/**
 * Ranges of the title to highlight. When the best match was another field
 * (a username, say), the title is matched on its own so a visible hit is
 * still highlighted.
 */
const titleRangesOf = (
  query: PreparedQuery | undefined,
  match: Match | undefined,
  fields: readonly PreparedField[],
  title: string,
): readonly MatchRange[] => {
  if (!match || !query) return []
  if (fields[match.fieldIndex]?.text === title) return match.ranges
  const titleField = fields.find((field) => field.text === title)
  return titleField ? (matchField(query, titleField)?.ranges ?? []) : []
}

const emptyContext: ReadSignal<QuickSearchContext> = { get: () => ({}), peek: () => ({}) }

type MessagesState = AsyncSectionState & { readonly hits: readonly MessageHit[] }
export type RankedRemoteUser = { readonly user: UserRow; readonly match: Match; readonly title: string; readonly titleRanges: readonly MatchRange[] }
type GlobalState = AsyncSectionState & { readonly users: readonly RankedRemoteUser[]; readonly messages: readonly MessageHit[] }

const idleMessages: MessagesState = { status: "idle", hits: [] }
const idleGlobal: GlobalState = { status: "idle", users: [], messages: [] }

type LocalResult = {
  readonly sections: readonly QuickSearchSection[]
  /** People already shown locally, never repeated under global results. */
  readonly userIds: ReadonlySet<string>
}

const chatItem = (candidate: ChatCandidate, section: QuickSearchSectionKind, query?: PreparedQuery, match?: Match): QuickSearchChatItem => ({
  kind: "chat",
  id: candidate.key,
  section,
  title: candidate.title,
  ...(candidate.subtitle !== undefined ? { subtitle: candidate.subtitle } : {}),
  titleRanges: titleRangesOf(query, match, candidate.fields, candidate.title),
  chatId: candidate.chatId,
  ...(candidate.peerUserId !== undefined ? { peerUserId: candidate.peerUserId } : {}),
  ...(candidate.spaceId !== undefined ? { spaceId: candidate.spaceId } : {}),
  ...(candidate.emoji !== undefined ? { emoji: candidate.emoji } : {}),
  unread: candidate.unread,
})

const messageItem = (hit: MessageHit, section: QuickSearchSectionKind, remote: boolean): QuickSearchMessageItem => ({
  kind: "message",
  id: `message:${hit.chatId}:${hit.messageId}`,
  section,
  title: hit.chatTitle,
  titleRanges: [],
  chatId: hit.chatId,
  messageId: hit.messageId,
  ...(hit.peerUserId !== undefined ? { peerUserId: hit.peerUserId } : {}),
  date: hit.date,
  snippet: hit.snippet,
  snippetRanges: hit.snippetRanges ?? [],
  remote,
})

const usageKeyOf = (item: QuickSearchItem): string | undefined => {
  switch (item.kind) {
    case "chat":
      return item.id
    case "user":
      return userUsageKey(item.userId)
    case "message":
      return item.peerUserId !== undefined ? userUsageKey(item.peerUserId) : chatUsageKey(item.chatId)
    default:
      return undefined
  }
}

// ---------------------------------------------------------------------------
// The model

export class QuickSearchModel {
  readonly #options: QuickSearchOptions
  readonly #context: ReadSignal<QuickSearchContext>
  readonly #messageDebounceMs: number
  readonly #remoteDelayMs: number
  readonly #exclude: ReadonlySet<string>
  readonly #commandFields = new WeakMap<Command, readonly PreparedField[]>()

  readonly #isOpen = signal(false)
  readonly #text = signal("")
  readonly #search = signal("")
  readonly #chosenId = signal<string | undefined>(undefined)
  readonly #messages = signal<MessagesState>(idleMessages)
  readonly #global = signal<GlobalState>(idleGlobal)
  readonly #arrival = signal<readonly ("messages" | "global")[]>([])

  #generation = 0
  #timers: unknown[] = []
  #controllers: AbortController[] = []

  /** Whether the palette is open. */
  readonly isOpen: ReadSignal<boolean> = this.#isOpen
  /** The text in the field, newlines turned into spaces. */
  readonly text: ReadSignal<string> = this.#text
  /** The query results are for: `text`, trimmed. */
  readonly query: ReadSignal<string> = this.#search
  readonly messagesState: ReadSignal<AsyncSectionState> = this.#messages
  readonly globalState: ReadSignal<AsyncSectionState> = this.#global

  readonly #local: ReadSignal<LocalResult>
  readonly #messagesSection: ReadSignal<QuickSearchSection | undefined>
  readonly #globalSection: ReadSignal<QuickSearchSection | undefined>
  /** Sections in display order. Empty sections are left out. */
  readonly sections: ReadSignal<readonly QuickSearchSection[]>
  /** Every item, in display order, IDs unique. */
  readonly items: ReadSignal<readonly QuickSearchItem[]>
  /** The highlighted item: the one the user moved to while it exists, else the first. */
  readonly activeId: ReadSignal<string | undefined>
  readonly activeItem: ReadSignal<QuickSearchItem | undefined>
  /** True while a debounce or a request is outstanding. */
  readonly isLoading: ReadSignal<boolean>
  readonly emptyState: ReadSignal<QuickSearchEmptyState>

  constructor(options: QuickSearchOptions) {
    this.#options = options
    this.#context = options.context ?? emptyContext
    this.#messageDebounceMs = options.timing?.messageDebounceMs ?? quickSearchTiming.messageDebounceMs
    this.#remoteDelayMs = options.timing?.remoteDelayMs ?? quickSearchTiming.remoteDelayMs
    this.#exclude = new Set(options.excludeCommands ?? ["app.quickSearch"])

    this.#local = computed(() => this.#computeLocal())
    this.#messagesSection = computed(() => this.#computeMessagesSection())
    this.#globalSection = computed(() => this.#computeGlobalSection())

    this.sections = computed(() => this.#computeSections())

    this.items = computed(() => this.sections.get().flatMap((section) => section.items))

    this.activeId = computed(() => {
      const items = this.items.get()
      const chosen = this.#chosenId.get()
      if (chosen !== undefined && items.some((item) => item.id === chosen)) return chosen
      return items[0]?.id
    })

    this.activeItem = computed(() => {
      const id = this.activeId.get()
      return id === undefined ? undefined : this.items.get().find((item) => item.id === id)
    })

    this.isLoading = computed(() => this.#messages.get().status === "pending" || this.#global.get().status === "pending")

    this.emptyState = computed<QuickSearchEmptyState>(() => {
      if (this.items.get().length > 0) return "results"
      if (this.isLoading.get()) return "loading"
      if (this.#messages.get().status === "error" || this.#global.get().status === "error") return "error"
      return this.#search.get().length > 0 ? "noResults" : "blank"
    })
  }

  // -------------------------------------------------------------------------
  // Lifecycle

  /** Open with an empty query; the first item is active. */
  open(): void {
    batch(() => {
      this.#reset()
      this.#isOpen.set(true)
    })
  }

  /** Close: cancel timers and requests, clear the query. */
  close(): void {
    batch(() => {
      this.#reset()
      this.#isOpen.set(false)
    })
  }

  dispose(): void {
    this.close()
  }

  /**
   * The field changed. Local results for the new query are readable as soon
   * as this returns; message and server searches are scheduled.
   */
  setQuery(value: string): void {
    const text = singleLine(value)
    const search = text.trim()
    batch(() => {
      this.#text.set(text)
      if (search === this.#search.peek()) return
      this.#search.set(search)
      this.#chosenId.set(undefined)
      this.#restartAsync(search)
    })
  }

  // -------------------------------------------------------------------------
  // Navigation

  /** Make an item active (pointer hover, or a programmatic choice). Ignored for an unknown ID. */
  setActive(id: string): void {
    if (this.items.peek().some((item) => item.id === id)) this.#chosenId.set(id)
  }

  next(): void {
    this.#moveBy(1)
  }

  previous(): void {
    this.#moveBy(-1)
  }

  first(): void {
    const first = this.items.peek()[0]
    if (first) this.#chosenId.set(first.id)
  }

  last(): void {
    const items = this.items.peek()
    const last = items[items.length - 1]
    if (last) this.#chosenId.set(last.id)
  }

  /** To the first item of the next section; stays put in the last one. */
  nextSection(): void {
    const sections = this.sections.peek()
    const index = this.#activeSectionIndex(sections)
    const target = sections[index + 1]?.items[0]
    if (target) this.#chosenId.set(target.id)
  }

  /** To the first item of this section, or of the previous section when already there. */
  previousSection(): void {
    const sections = this.sections.peek()
    const index = this.#activeSectionIndex(sections)
    const section = sections[index]
    if (!section) return
    const activeId = this.activeId.peek()
    const target = section.items[0]?.id !== activeId ? section.items[0] : sections[index - 1]?.items[0]
    if (target) this.#chosenId.set(target.id)
  }

  // -------------------------------------------------------------------------
  // Activation

  /**
   * Activate an item (default: the active one). Records usage for the
   * query, closes the palette, and returns what the app should do. An item
   * that is not in the current list (a stale click) returns `none`.
   */
  activate(item?: QuickSearchItem, intent: OpenIntent = "here"): QuickSearchOutcome {
    const id = item?.id ?? this.activeId.peek()
    const current = id === undefined ? undefined : this.items.peek().find((candidate) => candidate.id === id)
    if (!current) return { kind: "none" }

    const usageKey = usageKeyOf(current)
    if (usageKey !== undefined) this.#options.usage?.recordSelection(usageKey, this.#search.peek())

    const outcome = this.#outcomeOf(current, intent)
    this.close()
    return outcome
  }

  #outcomeOf(item: QuickSearchItem, intent: OpenIntent): QuickSearchOutcome {
    switch (item.kind) {
      case "chat":
        return { kind: "open", destination: { kind: "chat", chatId: item.chatId }, intent }
      case "user":
        return { kind: "openUser", userId: item.userId, intent }
      case "space":
        return { kind: "openSpace", spaceId: item.spaceId }
      case "command":
        return { kind: "runCommand", commandId: item.commandId }
      case "createThread":
        return { kind: "createThread", spaceId: item.spaceId, title: item.threadTitle }
      case "message":
        return { kind: "open", destination: { kind: "message", chatId: item.chatId, messageId: item.messageId }, intent }
    }
  }

  // -------------------------------------------------------------------------
  // Internals

  #moveBy(delta: number): void {
    const items = this.items.peek()
    if (items.length === 0) return
    const activeId = this.activeId.peek()
    const index = Math.max(0, items.findIndex((item) => item.id === activeId))
    const next = items[Math.min(items.length - 1, Math.max(0, index + delta))]
    if (next) this.#chosenId.set(next.id)
  }

  #activeSectionIndex(sections: readonly QuickSearchSection[]): number {
    const activeId = this.activeId.peek()
    return sections.findIndex((section) => section.items.some((item) => item.id === activeId))
  }

  #reset(): void {
    this.#cancelAsync()
    this.#generation++
    this.#text.set("")
    this.#search.set("")
    this.#chosenId.set(undefined)
    this.#messages.set(idleMessages)
    this.#global.set(idleGlobal)
    this.#arrival.set([])
  }

  #cancelAsync(): void {
    for (const timer of this.#timers) this.#options.clock.clearTimeout(timer)
    this.#timers = []
    for (const controller of this.#controllers) controller.abort()
    this.#controllers = []
  }

  #restartAsync(search: string): void {
    this.#cancelAsync()
    const generation = ++this.#generation
    this.#arrival.set([])
    const { messages, remote } = this.#options
    const prepared = prepareQuery(search)

    if (messages && isMessageSearchable(search)) {
      this.#messages.set({ status: "pending", hits: [] })
      const spaceId = this.#context.peek().spaceId
      this.#schedule(this.#messageDebounceMs, generation, async (signal) => {
        const hits = await messages.search(
          { query: search, ...(spaceId !== undefined ? { spaceId } : {}), limit: quickSearchLimits.messages, includeArchived: true, sort: "newest" },
          signal,
        )
        return () => {
          this.#messages.set({ status: "done", hits: hits.slice(0, quickSearchLimits.messages) })
          this.#arrive("messages")
        }
      }, (error) => {
        this.#messages.set({ status: "error", hits: [], error })
        this.#arrive("messages")
      })
    } else {
      this.#messages.set(idleMessages)
    }

    if (remote && prepared && prepared.compact.length >= 2) {
      this.#global.set({ status: "pending", users: [], messages: [] })
      this.#schedule(this.#remoteDelayMs, generation, async (signal) => {
        const result = await remote.search({ query: search, limit: quickSearchLimits.global }, signal)
        const users = rankRemoteUsers(result.users ?? [], prepared)
        const hits = (result.messages ?? []).slice(0, quickSearchLimits.messages)
        return () => {
          this.#global.set({ status: "done", users, messages: hits })
          this.#arrive("global")
        }
      }, (error) => {
        this.#global.set({ status: "error", users: [], messages: [], error })
        this.#arrive("global")
      })
    } else {
      this.#global.set(idleGlobal)
    }
  }

  /**
   * After `delayMs`, run `work` with a fresh abort signal. Its result is
   * applied only if the query is still the one it was started for.
   */
  #schedule(
    delayMs: number,
    generation: number,
    work: (signal: AbortSignal) => Promise<() => void>,
    fail: (error: unknown) => void,
  ): void {
    const timer = this.#options.clock.setTimeout(() => {
      this.#timers = this.#timers.filter((t) => t !== timer)
      if (generation !== this.#generation) return
      const controller = new AbortController()
      this.#controllers.push(controller)
      const settle = (apply: () => void) => {
        this.#controllers = this.#controllers.filter((c) => c !== controller)
        if (generation !== this.#generation || controller.signal.aborted) return
        batch(apply)
      }
      let started: Promise<() => void>
      try {
        started = work(controller.signal)
      } catch (error) {
        started = Promise.reject(error)
      }
      started.then(
        (apply) => settle(apply),
        (error: unknown) => settle(() => fail(error)),
      )
    }, delayMs)
    this.#timers.push(timer)
  }

  #arrive(section: "messages" | "global"): void {
    const order = this.#arrival.peek()
    if (!order.includes(section)) this.#arrival.set([...order, section])
  }

  #fieldsOf(command: Command): readonly PreparedField[] {
    let fields = this.#commandFields.get(command)
    if (!fields) {
      const keywords = this.#options.commandKeywords?.(command) ?? []
      const p = fieldPriority.command
      fields = prepareFields([
        { text: command.title, priority: p.title },
        ...keywords.map((text) => ({ text, priority: p.keyword })),
        { text: [command.title, ...keywords].join(" "), priority: p.all },
      ])
      this.#commandFields.set(command, fields)
    }
    return fields
  }

  #computeLocal(): LocalResult {
    const search = this.#search.get()
    const query = prepareQuery(search)
    const usageStore = this.#options.usage
    usageStore?.revision.get()
    const usage: ReadonlyMap<string, UsageSignal> = usageStore ? usageStore.signals(search, (this.#options.now ?? Date.now)()) : new Map()
    const usageOf = (key: string) => usage.get(key) ?? noUsage
    const local = this.#options.local
    const chats = local?.chats.get() ?? []
    const sections: QuickSearchSection[] = []
    const userIds = new Set<string>()
    const push = (kind: QuickSearchSectionKind, items: readonly QuickSearchItem[]) => {
      if (items.length > 0) sections.push({ kind, title: quickSearchSectionTitles[kind], items })
    }
    const noteUser = (item: QuickSearchItem) => {
      if (item.kind === "chat" && item.peerUserId !== undefined) userIds.add(item.peerUserId)
      if (item.kind === "user") userIds.add(item.userId)
    }

    if (!query) {
      // Empty query: what the user goes to most, then the top of the sidebar.
      const suggested = chats
        .map((candidate, order) => ({ candidate, order, usage: usageOf(candidate.key) }))
        .filter((entry) => entry.usage.switchFrecency > 0)
        .sort(compareSuggestions)
        .slice(0, quickSearchLimits.suggestions)
      const suggestedKeys = new Set(suggested.map((entry) => entry.candidate.key))
      const suggestions = suggested.map((entry) => chatItem(entry.candidate, "suggestions"))
      const rest: QuickSearchItem[] = []
      for (const candidate of chats) {
        if (rest.length >= quickSearchLimits.emptyQueryChats) break
        if (!suggestedKeys.has(candidate.key)) rest.push(chatItem(candidate, "chats"))
      }
      suggestions.forEach(noteUser)
      rest.forEach(noteUser)
      push("suggestions", suggestions)
      push("chats", rest)
      push("commands", this.#commandItems(undefined))
      return { sections, userIds }
    }

    // Chats, ranked the Mac way, then mixed with people who have no chat by score.
    const contextSpace = this.#context.get().spaceId
    const matchedChats: { candidate: ChatCandidate; match: Match; usage: UsageSignal; order: number; currentSpace: boolean; pinned: boolean; unread: boolean; lastActivity: number }[] = []
    chats.forEach((candidate, order) => {
      const match = matchFields(query, candidate.fields)
      if (!match) return
      matchedChats.push({
        candidate,
        match,
        usage: usageOf(candidate.key),
        order,
        currentSpace: contextSpace !== undefined && candidate.spaceId === contextSpace,
        pinned: candidate.pinned,
        unread: candidate.unread,
        lastActivity: candidate.lastActivity,
      })
    })
    matchedChats.sort(compareRanked)

    const users = local?.users.get() ?? []
    const matchedUsers: { candidate: UserCandidate; match: Match; order: number }[] = []
    users.forEach((candidate, order) => {
      const match = matchFields(query, candidate.fields)
      if (match) matchedUsers.push({ candidate, match, order })
    })
    matchedUsers.sort(compareByMatch)

    const mixed: { item: QuickSearchItem; score: number; order: number }[] = []
    for (const entry of matchedChats.slice(0, quickSearchLimits.chats)) {
      mixed.push({ item: chatItem(entry.candidate, "chats", query, entry.match), score: rankScore(entry.match, entry.usage), order: mixed.length })
    }
    for (const entry of matchedUsers.slice(0, quickSearchLimits.chats)) {
      const c = entry.candidate
      mixed.push({
        item: {
          kind: "user",
          id: c.key,
          section: "chats",
          title: c.title,
          ...(c.subtitle !== undefined ? { subtitle: c.subtitle } : {}),
          titleRanges: titleRangesOf(query, entry.match, c.fields, c.title),
          userId: c.userId,
          remote: false,
        },
        score: rankScore(entry.match),
        order: mixed.length,
      })
    }
    mixed.sort((a, b) => b.score - a.score || a.order - b.order)
    const chatItems = mixed.slice(0, quickSearchLimits.chats).map((entry) => entry.item)
    chatItems.forEach(noteUser)
    push("chats", chatItems)

    const spaces = (local?.spaces.get() ?? [])
      .map((candidate, order) => ({ candidate, order, match: matchFields(query, candidate.fields) }))
      .filter((entry): entry is { candidate: SpaceCandidate; order: number; match: Match } => entry.match !== undefined)
      .sort(compareByMatch)
      .slice(0, quickSearchLimits.spaces)
      .map(
        (entry): QuickSearchItem => ({
          kind: "space",
          id: entry.candidate.key,
          section: "spaces",
          title: entry.candidate.title,
          titleRanges: titleRangesOf(query, entry.match, entry.candidate.fields, entry.candidate.title),
          spaceId: entry.candidate.spaceId,
        }),
      )
    push("spaces", spaces)
    push("commands", this.#commandItems(query))
    return { sections, userIds }
  }

  #commandItems(query: PreparedQuery | undefined): QuickSearchItem[] {
    const registry = this.#options.commands
    if (!registry) return []
    const ranked: { command: Command; match?: Match; order: number }[] = []
    registry.commands.get().forEach((command, order) => {
      if (command.inPalette === false || this.#exclude.has(command.id) || !command.enabled.get()) return
      if (!query) {
        ranked.push({ command, order })
        return
      }
      const match = matchFields(query, this.#fieldsOf(command))
      if (match) ranked.push({ command, match, order })
    })
    if (query) ranked.sort((a, b) => (a.match && b.match ? compareMatches(a.match, b.match) : 0) || a.order - b.order)
    return ranked.map(({ command, match }) => ({
      kind: "command",
      id: `command:${command.id}`,
      section: "commands",
      title: command.title,
      ...(command.description !== undefined ? { subtitle: command.description } : {}),
      titleRanges: titleRangesOf(query, match, this.#fieldsOf(command), command.title),
      commandId: command.id,
      category: command.category,
    }))
  }

  /** The local messages section; its own computed so its items keep identity when other sections change. */
  #computeMessagesSection(): QuickSearchSection | undefined {
    const items = this.#messages.get().hits.map((hit) => messageItem(hit, "messages", false))
    return items.length > 0 ? { kind: "messages", title: quickSearchSectionTitles.messages, items } : undefined
  }

  /** Server results: people not already shown locally, then server message hits. */
  #computeGlobalSection(): QuickSearchSection | undefined {
    const local = this.#local.get()
    const global = this.#global.get()
    const items: QuickSearchItem[] = []
    for (const { user, title, titleRanges } of global.users) {
      if (local.userIds.has(user.id)) continue
      const username = user.username?.trim().replace(/^@+/, "")
      items.push({
        kind: "user",
        id: userUsageKey(user.id),
        section: "global",
        title,
        ...(username ? { subtitle: `@${username}` } : user.email ? { subtitle: user.email } : {}),
        titleRanges,
        userId: user.id,
        remote: true,
        user,
      })
    }
    for (const hit of global.messages) items.push(messageItem(hit, "global", true))
    return items.length > 0 ? { kind: "global", title: quickSearchSectionTitles.global, items } : undefined
  }

  #computeSections(): readonly QuickSearchSection[] {
    const local = this.#local.get()
    const sections: QuickSearchSection[] = [...local.sections]
    const messages = this.#messages.get()
    const global = this.#global.get()
    const asyncSections = new Map<"messages" | "global", QuickSearchSection>()
    const messagesSection = this.#messagesSection.get()
    if (messagesSection) asyncSections.set("messages", messagesSection)
    const globalSection = this.#globalSection.get()
    if (globalSection) asyncSections.set("global", globalSection)

    // The Create row: a non-empty query in a space, every search finished
    // without error, and nothing found anywhere (`createThreadResult`).
    const search = this.#search.get()
    const spaceId = this.#context.get().spaceId
    const settled = (state: AsyncSectionState) => state.status === "idle" || state.status === "done"
    if (
      search.length > 0 &&
      spaceId !== undefined &&
      settled(messages) &&
      settled(global) &&
      sections.length === 0 &&
      asyncSections.size === 0
    ) {
      sections.push({
        kind: "commands",
        title: quickSearchSectionTitles.commands,
        items: [
          {
            kind: "createThread",
            id: `create:${spaceId}:${search.toLowerCase()}`,
            section: "commands",
            title: `Create "${search}"`,
            titleRanges: [],
            spaceId,
            threadTitle: search,
          },
        ],
      })
    }

    // Async sections append below in the order they arrived, so nothing shown moves.
    for (const kind of this.#arrival.get()) {
      const section = asyncSections.get(kind)
      if (section) sections.push(section)
    }

    // IDs are unique across the list: the first (higher) occurrence wins.
    // A section without duplicates keeps its object, so views can compare by identity.
    const seen = new Set<string>()
    const out: QuickSearchSection[] = []
    for (const section of sections) {
      const items = section.items.filter((item) => {
        if (seen.has(item.id)) return false
        seen.add(item.id)
        return true
      })
      if (items.length === section.items.length) out.push(section)
      else if (items.length > 0) out.push({ ...section, items })
    }
    return out
  }
}

/** The Mac's `rankGlobalUsers`: keep people the query matches, best first, at most 20. */
export const rankRemoteUsers = (users: readonly UserRow[], query: PreparedQuery): RankedRemoteUser[] => {
  const ranked: (RankedRemoteUser & { order: number })[] = []
  users.forEach((user, order) => {
    if (!user || typeof user !== "object") return
    const fields = remoteUserFields(user)
    const match = matchFields(query, fields)
    if (!match) return
    const title = userDisplayName(user)
    ranked.push({ user, match, title, titleRanges: titleRangesOf(query, match, fields, title), order })
  })
  ranked.sort((a, b) => compareMatches(a.match, b.match) || a.title.localeCompare(b.title) || a.order - b.order)
  return ranked.slice(0, quickSearchLimits.global).map(({ user, match, title, titleRanges }) => ({ user, match, title, titleRanges }))
}

export const createQuickSearchModel = (options: QuickSearchOptions): QuickSearchModel => new QuickSearchModel(options)
