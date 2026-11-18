/**
 * Where Quick Search results come from. Three kinds of source, each a small
 * interface the app implements:
 *
 * - A synchronous local source of candidates already in memory: chats (from
 *   dialogs), known users without a direct chat, and spaces. Commands come
 *   from the `CommandRegistry` directly.
 * - An asynchronous local message search: the core's full-text query.
 * - An asynchronous remote search: users (and later messages) on the server.
 *
 * Candidates carry prepared fields (see `match.ts`) so a keystroke only
 * matches, never re-normalizes. `createRowLocalSource` builds candidates from
 * view-store rows and reuses a candidate while its rows keep their identity.
 */

import { userDisplayName } from "@inline/chat-ui"
import type { ChatRow, DialogRow, SpaceRow, UserRow } from "@inline/core-protocol"
import type { ChatID, MessageID, SpaceID, UserID } from "@inline/ids"
import { computed, type ReadSignal } from "@inline/reactive"
import { normalizeText, prepareFields, type MatchRange, type PreparedField } from "./match"

// ---------------------------------------------------------------------------
// Field priorities, from the Mac app

/**
 * Field priorities break ties inside a match tier. Values are the Mac app's:
 * `InlineSearchChatCatalog.Entry`, `KnownUserEntry`, `rankGlobalUsers` in
 * `QuickSearchPopover.swift`, and `CommandBarCatalogService.projectSpaces`.
 */
export const fieldPriority = {
  chat: { title: 400, username: 500, email: 200, spaceTitle: 100, parentTitle: 100 },
  knownUser: { name: 500, username: 600, email: 200 },
  remoteUser: { name: 500, fullName: 450, atUsername: 600, username: 550, email: 300 },
  space: { name: 500 },
  command: { title: 640, keyword: 420, all: 260 },
} as const

// ---------------------------------------------------------------------------
// Candidates

/** Usage keys: one per person or chat, so a direct chat and its user share one. */
export const userUsageKey = (userId: UserID): string => `user:${userId}`
export const chatUsageKey = (chatId: ChatID): string => `chat:${chatId}`

export type ChatCandidate = {
  readonly kind: "chat"
  /** Item ID and usage key: `user:<id>` for a direct chat, `chat:<id>` otherwise. */
  readonly key: string
  readonly chatId: ChatID
  readonly title: string
  readonly subtitle?: string
  readonly emoji?: string
  /** Set for a direct chat. */
  readonly peerUserId?: UserID
  readonly spaceId?: SpaceID
  readonly parentChatId?: ChatID
  readonly pinned: boolean
  readonly unread: boolean
  readonly archived: boolean
  /** Seconds since the epoch of the last activity; 0 when unknown. */
  readonly lastActivity: number
  /** The field list; `fields[0]` is the title, which the view highlights. */
  readonly fields: readonly PreparedField[]
}

export type UserCandidate = {
  readonly kind: "user"
  /** `user:<id>`. */
  readonly key: string
  readonly userId: UserID
  readonly title: string
  readonly subtitle?: string
  readonly fields: readonly PreparedField[]
}

export type SpaceCandidate = {
  readonly kind: "space"
  /** `space:<id>`. */
  readonly key: string
  readonly spaceId: SpaceID
  readonly title: string
  readonly fields: readonly PreparedField[]
}

/** The synchronous local source. Every list is a signal so Quick Search follows the store. */
export interface QuickSearchLocalSource {
  /** Chats in sidebar order, archived ones included. The empty query lists them in this order. */
  readonly chats: ReadSignal<readonly ChatCandidate[]>
  /** People the account knows who have no direct chat in `chats`. */
  readonly users: ReadSignal<readonly UserCandidate[]>
  readonly spaces: ReadSignal<readonly SpaceCandidate[]>
}

const trimmed = (value: string | undefined): string | undefined => {
  const text = value?.trim()
  return text ? text : undefined
}

/**
 * A chat's title by the Mac sidebar rule: a direct chat shows the peer's
 * name, a thread its title or "New thread". The same rule as
 * `features/helpers.ts` `chatTitle`, kept here so this directory stands alone.
 */
export const quickSearchChatTitle = (chat: ChatRow | undefined, peer: UserRow | undefined, peerUserId?: UserID): string => {
  const isDirect = peerUserId !== undefined || chat?.peerUserId !== undefined
  if (isDirect && peer) return userDisplayName(peer)
  const title = trimmed(chat?.title)
  if (title) return title
  if (chat && !isDirect) return "New thread"
  return "Chat"
}

/** The subtitle the Mac shows: the parent thread, else the space, else `@username` or email. */
const userSubtitle = (user: UserRow | undefined): string | undefined => {
  const username = trimmed(user?.username)
  return username ? `@${username.replace(/^@+/, "")}` : trimmed(user?.email)
}

export type ChatCandidateInput = {
  readonly chatId: ChatID
  readonly chat?: ChatRow
  readonly dialog?: DialogRow
  readonly peer?: UserRow
  readonly space?: SpaceRow
  readonly parent?: ChatRow
  readonly parentPeer?: UserRow
}

export const chatCandidate = (input: ChatCandidateInput): ChatCandidate => {
  const { chat, dialog, peer, space, parent } = input
  const peerUserId = dialog?.peerUserId ?? chat?.peerUserId
  const title = quickSearchChatTitle(chat, peer, peerUserId)
  const parentTitle = parent ? quickSearchChatTitle(parent, input.parentPeer) : undefined
  const spaceTitle = trimmed(space?.name)
  const p = fieldPriority.chat
  const subtitle = parentTitle ?? spaceTitle ?? (peerUserId !== undefined ? userSubtitle(peer) : undefined)
  const spaceId = dialog?.spaceId ?? chat?.spaceId
  return {
    kind: "chat",
    key: peerUserId !== undefined ? userUsageKey(peerUserId) : chatUsageKey(input.chatId),
    chatId: input.chatId,
    title,
    ...(subtitle !== undefined ? { subtitle } : {}),
    ...(chat?.emoji ? { emoji: chat.emoji } : {}),
    ...(peerUserId !== undefined ? { peerUserId } : {}),
    ...(spaceId !== undefined ? { spaceId } : {}),
    ...(chat?.parentChatId !== undefined ? { parentChatId: chat.parentChatId } : {}),
    pinned: dialog?.pinned ?? false,
    unread: (dialog?.unreadCount ?? 0) > 0 || (dialog?.unreadMark ?? false),
    archived: dialog?.archived ?? false,
    lastActivity: chat?.lastActivityDate ?? 0,
    fields: prepareFields([
      { text: title, priority: p.title },
      { text: peerUserId !== undefined ? trimmed(peer?.username)?.replace(/^@+/, "") : undefined, priority: p.username },
      { text: peerUserId !== undefined ? peer?.email : undefined, priority: p.email },
      { text: spaceTitle, priority: p.spaceTitle },
      { text: parentTitle, priority: p.parentTitle },
    ]),
  }
}

export const userCandidate = (user: UserRow): UserCandidate => {
  const p = fieldPriority.knownUser
  const title = userDisplayName(user)
  const subtitle = userSubtitle(user)
  return {
    kind: "user",
    key: userUsageKey(user.id),
    userId: user.id,
    title,
    ...(subtitle !== undefined ? { subtitle } : {}),
    fields: prepareFields([
      { text: title, priority: p.name },
      { text: trimmed(user.username)?.replace(/^@+/, ""), priority: p.username },
      { text: user.email, priority: p.email },
    ]),
  }
}

export const spaceCandidate = (space: SpaceRow): SpaceCandidate => ({
  kind: "space",
  key: `space:${space.id}`,
  spaceId: space.id,
  title: trimmed(space.name) ?? "Space",
  fields: prepareFields([{ text: space.name, priority: fieldPriority.space.name }]),
})

/** The rows Quick Search reads, as the app's view store holds them. */
export type QuickSearchRows = {
  /** Dialogs in sidebar order. */
  readonly dialogs: readonly DialogRow[]
  readonly chat: (id: ChatID) => ChatRow | undefined
  readonly user: (id: UserID) => UserRow | undefined
  readonly space: (id: SpaceID) => SpaceRow | undefined
  /** Users the account knows (members, contacts). Those with a direct chat are skipped. */
  readonly users?: readonly UserRow[]
  readonly spaces?: readonly SpaceRow[]
  /** The signed-in user, never offered as a person to message. */
  readonly selfId?: UserID
}

type ChatCacheEntry = {
  readonly inputs: readonly unknown[]
  readonly candidate: ChatCandidate
}

/**
 * A local source over rows. Re-running it after a store change rebuilds only
 * the candidates whose rows changed identity (rows are immutable, see
 * `reactivity.md`), so field preparation is paid once per row version.
 */
export const createRowLocalSource = (rows: ReadSignal<QuickSearchRows>): QuickSearchLocalSource => {
  let chatCache = new Map<string, ChatCacheEntry>()
  let userCache = new Map<UserID, { row: UserRow; candidate: UserCandidate }>()
  let spaceCache = new Map<SpaceID, { row: SpaceRow; candidate: SpaceCandidate }>()

  const chats = computed<readonly ChatCandidate[]>(() => {
    const input = rows.get()
    const next = new Map<string, ChatCacheEntry>()
    const out: ChatCandidate[] = []
    for (const dialog of input.dialogs) {
      const chat = input.chat(dialog.chatId)
      const peerUserId = dialog.peerUserId ?? chat?.peerUserId
      const peer = peerUserId !== undefined ? input.user(peerUserId) : undefined
      const spaceId = dialog.spaceId ?? chat?.spaceId
      const space = spaceId !== undefined ? input.space(spaceId) : undefined
      const parent = chat?.parentChatId !== undefined ? input.chat(chat.parentChatId) : undefined
      const parentPeer = parent?.peerUserId !== undefined ? input.user(parent.peerUserId) : undefined
      const inputs = [dialog, chat, peer, space, parent, parentPeer]
      const previous = chatCache.get(dialog.chatId)
      const reuse = previous && previous.inputs.every((value, index) => value === inputs[index])
      const candidate = reuse
        ? previous.candidate
        : chatCandidate({
            chatId: dialog.chatId,
            dialog,
            ...(chat ? { chat } : {}),
            ...(peer ? { peer } : {}),
            ...(space ? { space } : {}),
            ...(parent ? { parent } : {}),
            ...(parentPeer ? { parentPeer } : {}),
          })
      next.set(dialog.chatId, { inputs, candidate })
      out.push(candidate)
    }
    chatCache = next
    return out
  })

  const users = computed<readonly UserCandidate[]>(() => {
    const input = rows.get()
    const direct = new Set<string>()
    for (const candidate of chats.get()) if (candidate.peerUserId !== undefined) direct.add(candidate.peerUserId)
    const next = new Map<UserID, { row: UserRow; candidate: UserCandidate }>()
    const out: UserCandidate[] = []
    for (const user of input.users ?? []) {
      if (user.id === input.selfId || direct.has(user.id) || next.has(user.id)) continue
      const previous = userCache.get(user.id)
      const candidate = previous && previous.row === user ? previous.candidate : userCandidate(user)
      next.set(user.id, { row: user, candidate })
      out.push(candidate)
    }
    userCache = next
    return out
  })

  const spaces = computed<readonly SpaceCandidate[]>(() => {
    const next = new Map<SpaceID, { row: SpaceRow; candidate: SpaceCandidate }>()
    const out: SpaceCandidate[] = []
    for (const space of rows.get().spaces ?? []) {
      if (next.has(space.id)) continue
      const previous = spaceCache.get(space.id)
      const candidate = previous && previous.row === space ? previous.candidate : spaceCandidate(space)
      next.set(space.id, { row: space, candidate })
      out.push(candidate)
    }
    spaceCache = next
    return out
  })

  return { chats, users, spaces }
}

// ---------------------------------------------------------------------------
// Message search (local full-text index in the core)

export type MessageSearchSort = "newest" | "relevance"

/** What Quick Search asks the core's full-text index. The Mac's `LocalMessageSearchOptions`. */
export type MessageSearchRequest = {
  /** The trimmed query. Every word must prefix a word of the message (FTS5 prefix tokens). */
  readonly query: string
  /** Only messages in this space's chats. Quick Search passes the selected space, as the Mac does. */
  readonly spaceId?: SpaceID
  readonly limit: number
  readonly includeArchived: boolean
  readonly sort: MessageSearchSort
}

export type MessageHit = {
  readonly chatId: ChatID
  readonly messageId: MessageID
  /** The chat's title, as the sidebar shows it. */
  readonly chatTitle: string
  /** Set when the chat is a direct chat; usage is recorded for that person. */
  readonly peerUserId?: UserID
  readonly spaceId?: SpaceID
  readonly fromId?: UserID
  /** Seconds since the epoch. */
  readonly date: number
  /** A short excerpt around the first hit (see `messageSnippet`). */
  readonly snippet: string
  /** Ranges in `snippet` to highlight. */
  readonly snippetRanges?: readonly MatchRange[]
}

export interface QuickSearchMessageSource {
  /**
   * Search local messages. Must reject or resolve promptly once `signal`
   * aborts; Quick Search discards whatever arrives after that anyway.
   */
  search(request: MessageSearchRequest, signal: AbortSignal): Promise<readonly MessageHit[]>
}

const wordCharGlobal = /[\p{L}\p{N}]/gu

/** The Mac rule (`LocalMessageSearch.isSearchable`): at least two letters or digits. */
export const isMessageSearchable = (query: string): boolean => {
  if (typeof query !== "string") return false
  const matches = query.trim().match(wordCharGlobal)
  return (matches?.length ?? 0) >= 2
}

/**
 * An excerpt of `text` around the first query word it contains, with
 * ellipses where it was cut, and the word's range in the excerpt. A port of
 * the Mac's `LocalMessageSearch.snippet` (radius 70), case and diacritic
 * insensitive. For the core and for fakes.
 */
export const messageSnippet = (
  text: string,
  query: string,
  radius = 70,
): { readonly snippet: string; readonly ranges: readonly MatchRange[] } => {
  const whole = (typeof text === "string" ? text : "").replace(/\s+/g, " ").trim()
  if (whole.length === 0) return { snippet: "", ranges: [] }
  const clip = (value: string, max: number) => (value.length > max ? `${value.slice(0, max)}...` : value)
  const words = (typeof query === "string" ? query : "").split(/\s+/).filter(isMessageSearchable).map(normalizeText)
  // Fold the text one UTF-16 unit at a time so indexes map back one to one.
  const folded = Array.from(whole, (char) => {
    const value = normalizeText(char)
    return value.length === char.length ? value : char.toLowerCase().length === char.length ? char.toLowerCase() : char
  }).join("")
  let at = -1
  let length = 0
  for (const word of words) {
    if (word.length === 0) continue
    const index = folded.indexOf(word)
    if (index >= 0) {
      at = index
      length = word.length
      break
    }
  }
  if (at < 0) return { snippet: clip(whole, radius * 2), ranges: [] }
  const start = Math.max(0, at - radius)
  const end = Math.min(whole.length, at + length + radius)
  const prefix = start > 0 ? "..." : ""
  const suffix = end < whole.length ? "..." : ""
  const snippet = prefix + whole.slice(start, end) + suffix
  const offset = prefix.length + at - start
  return { snippet, ranges: [[offset, offset + length]] }
}

// ---------------------------------------------------------------------------
// Remote search (the server)

export type RemoteSearchRequest = {
  readonly query: string
  readonly limit: number
}

export type RemoteSearchResult = {
  /** People on the server matching the query (the Mac's `searchContacts`). */
  readonly users: readonly UserRow[]
  /** Server-side message hits, when the server offers them. Shown under global results. */
  readonly messages?: readonly MessageHit[]
}

export interface QuickSearchRemoteSource {
  /** Search the server. Must honor `signal`. */
  search(request: RemoteSearchRequest, signal: AbortSignal): Promise<RemoteSearchResult>
}

/** Fields of a remote user, with the Mac's priorities (`rankGlobalUsers`). */
export const remoteUserFields = (user: UserRow): PreparedField[] => {
  const p = fieldPriority.remoteUser
  const username = trimmed(user.username)?.replace(/^@+/, "")
  const fullName = [trimmed(user.firstName), trimmed(user.lastName)].filter(Boolean).join(" ")
  return prepareFields([
    { text: userDisplayName(user), priority: p.name },
    { text: fullName, priority: p.fullName },
    { text: username ? `@${username}` : undefined, priority: p.atUsername },
    { text: username, priority: p.username },
    { text: user.email, priority: p.email },
  ])
}
