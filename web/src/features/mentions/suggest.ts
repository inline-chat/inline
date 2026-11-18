/**
 * `@` mention suggestions for one chat's composer: the `suggest` function the
 * composer model takes (`web/src/features/composer`).
 *
 * Who is offered, after the Mac (`InlineKit/ViewModels/MentionCandidatesSource.swift`
 * `roster`, `MentionCompletionViewModel.swift`):
 *
 * - people with access to the chat (the participants model's `access`),
 *   members of the chat's space, the space's user groups, and, when given,
 *   people the viewer has direct messages with; never the viewer;
 * - each person once, under the strongest source: participant, then space
 *   member, then direct chat (the Mac's owned bots and Agents are not in the
 *   contract yet);
 * - people known only from a direct chat appear only when searched.
 *
 * Order without a query (`precedes`): access to the chat first; then who
 * spoke in the chat most recently; pinned direct chats; the latest direct
 * message; then groups, participants, space members and direct-chat people
 * in that order; then name; then ID. With a query, results are bucketed by
 * how well they match (an exact username, an exact name, whole words, a
 * prefix, initials, a substring, a group's description) and keep that order
 * inside each bucket. Matching uses the app's one name matcher
 * (`@inline/view/quick-search`), so scripts, accents and Persian and Arabic
 * letter variants fold the same way everywhere; its fuzzy tier is not used
 * here, as the Mac offers no fuzzy mentions.
 *
 * Synchronous: everything comes from the store, so the first keystroke has
 * rows. `suggest` reads signals, so the composer's list updates by itself as
 * the member list completes or a name arrives.
 */

import type { MemberRow, RowKey, UserGroupRow, UserRow } from "@inline/core-protocol"
import type { Trigger } from "@inline/composer"
import type { SpaceID, UserID } from "@inline/ids"
import { computed, effect, scope, signal, untracked, type ReadSignal, type StoreClient, type SubscriptionHandle } from "@inline/reactive"
import { userAvatarSeed, userDisplayName } from "@inline/chat-ui"
import {
  matchField,
  MatchTier,
  normalizeText,
  prepareField,
  prepareQuery,
  type PreparedField,
  type PreparedQuery,
} from "@inline/view/quick-search"
import type { ComposerSuggestion } from "../composer"
import type { ParticipantAccess } from "../chat-info/participants-model"

/** Where a person is offered from, strongest first (`MentionCompletionSource`). */
export type MentionSource = "participant" | "spaceMember" | "directChat"

/** What a list row and the mention policy need beyond the composer's fields. */
export type MentionTarget =
  | { readonly kind: "user"; readonly userId: UserID; readonly bot: boolean; readonly source: MentionSource; readonly hasAccess: boolean }
  | { readonly kind: "group"; readonly groupId: string; readonly hasAccess: boolean; readonly memberCount: number }

/**
 * One row of the list. `item` is what the composer inserts (a mention atom
 * for a user or a group, labelled "@First" or "@Group" as on the Mac).
 */
export type MentionSuggestion = ComposerSuggestion & { readonly mention: MentionTarget }

/** A person the viewer has a direct chat with, from the sidebar. */
export type DirectPeer = {
  readonly userId: UserID
  /** Seconds since the epoch of the chat's last message. */
  readonly lastMessageDate?: number
  readonly pinned?: boolean
}

export type MentionSuggestionsOptions = {
  readonly client: StoreClient
  readonly viewerId: UserID
  /** The participants model of the chat (its `access` and `spaceId`). */
  readonly participants: { readonly access: ReadSignal<ParticipantAccess>; readonly spaceId: ReadSignal<SpaceID | undefined> }
  /** Who spoke in the chat, most recent first (`recentSenders`). */
  readonly recentSenders?: ReadSignal<readonly UserID[]>
  /** The viewer's direct chats, for people outside the chat (searched only). */
  readonly directPeers?: ReadSignal<readonly DirectPeer[]>
  /** Most rows returned. Default 50. */
  readonly limit?: number
}

export type MentionSuggestions = {
  /** The composer model's `suggest` option. Rows for an `@` trigger, nothing for others. */
  readonly suggest: (trigger: Trigger) => readonly MentionSuggestion[]
  /** Rows for a query (the text after `@`). */
  rows(query: string): readonly MentionSuggestion[]
  /** Every candidate in the query-independent order, for tests and diagnostics. */
  readonly candidates: ReadSignal<readonly Candidate[]>
  dispose(): void
}

type FieldRole = "username" | "name" | "detail"

type Candidate = {
  readonly key: string
  readonly hasAccess: boolean
  /** 0 spoke last; `Infinity` when they did not speak recently. */
  readonly recentRank: number
  readonly pinned: boolean
  readonly lastDirectDate: number
  readonly sortRank: number
  readonly sortText: string
  readonly id: string
  readonly offeredWithoutQuery: boolean
  readonly fields: readonly { readonly field: PreparedField; readonly role: FieldRole }[]
  readonly suggestion: MentionSuggestion
}

/** How many of the chat's latest messages decide who spoke recently (Mac `recentSenderWindow`). */
export const RECENT_SENDER_WINDOW = 100

const sourceRank: Record<MentionSource, number> = { participant: 1, spaceMember: 3, directChat: 4 }

/** The Mac's `MentionCompletionCandidate.precedes`. */
const precedes = (a: Candidate, b: Candidate): number => {
  if (a.hasAccess !== b.hasAccess) return a.hasAccess ? -1 : 1
  if (a.recentRank !== b.recentRank) return a.recentRank < b.recentRank ? -1 : 1
  if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
  if (a.lastDirectDate !== b.lastDirectDate) return b.lastDirectDate - a.lastDirectDate
  if (a.sortRank !== b.sortRank) return a.sortRank - b.sortRank
  if (a.sortText !== b.sortText) return a.sortText < b.sortText ? -1 : 1
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

/** "@Ada" for a person (a bot by its name), "@Design" for a group (`MentionCompletionViewModel.mentionText`). */
export const mentionLabel = (user: UserRow | undefined): string => {
  const botName = user?.bot ? user.firstName?.trim() : undefined
  if (botName) return `@${botName}`
  const name = userDisplayName(user)
  return `@${name.split(" ")[0] || name}`
}

const groupSubtitle = (group: UserGroupRow): string => {
  const count = `${group.memberCount} ${group.memberCount === 1 ? "person" : "people"}`
  const description = group.description?.trim()
  return description ? `${description} - ${count}` : count
}

/** Whether the query's words appear as whole consecutive words of the field (`containsExactTokenSequence`). */
const hasWholeWords = (query: PreparedQuery, field: PreparedField): boolean =>
  query.compact.length >= 2 && ` ${field.normalized} `.includes(` ${query.normalized} `)

/** The Mac's match ranks, best first; undefined when no field matches well enough. */
const bucketOf = (query: PreparedQuery, candidate: Candidate): number | undefined => {
  let best: number | undefined
  for (const { field, role } of candidate.fields) {
    const match = matchField(query, field)
    if (!match || match.tier === MatchTier.fuzzy) continue
    let bucket: number
    if (role === "detail") bucket = 6
    else if (match.tier === MatchTier.exact) bucket = role === "username" ? 0 : 1
    else if (match.tier === MatchTier.fieldPrefix || match.tier === MatchTier.tokenPrefix) bucket = role === "name" && hasWholeWords(query, field) ? 2 : 3
    else if (match.tier === MatchTier.acronym) bucket = 4
    else bucket = 5
    if (best === undefined || bucket < best) best = bucket
    if (best === 0) break
  }
  return best
}

const BUCKETS = 7

/**
 * Who spoke in a chat, most recent first, from its message window (a
 * `ChatModel`'s `rowKeys` and `row`). Reads the newest `RECENT_SENDER_WINDOW`
 * rows; the viewer is filtered out later.
 */
export const recentSenders = (chat: {
  readonly rowKeys: ReadSignal<readonly RowKey[]>
  row(key: RowKey): ReadSignal<{ readonly fromId: UserID } | undefined>
}): ReadSignal<readonly UserID[]> =>
  computed(
    () => {
      const keys = chat.rowKeys.get()
      const seen = new Set<UserID>()
      const out: UserID[] = []
      for (let i = keys.length - 1, read = 0; i >= 0 && read < RECENT_SENDER_WINDOW; i--, read++) {
        const key = keys[i]
        if (key === undefined) continue
        const from = chat.row(key).get()?.fromId
        if (from === undefined || seen.has(from)) continue
        seen.add(from)
        out.push(from)
      }
      return out
    },
    { equals: (a, b) => a.length === b.length && a.every((id, i) => id === b[i]) },
  )

export const createMentionSuggestions = (options: MentionSuggestionsOptions): MentionSuggestions => {
  const { client, viewerId, participants } = options
  const store = client.store
  const limit = options.limit ?? 50

  // Space members and user groups of the chat's space, followed as the space changes.
  const spaceLists = signal<{ id: SpaceID; members: SubscriptionHandle; groups: SubscriptionHandle } | undefined>(undefined)
  const stopScope = scope(() => {
    effect(() => {
      const id = participants.spaceId.get()
      untracked(() => {
        const space = spaceLists.peek()
        if (space?.id === id) return
        space?.members.unsubscribe()
        space?.groups.unsubscribe()
        spaceLists.set(
          id === undefined
            ? undefined
            : { id, members: client.subscribe({ kind: "spaceMembers", spaceId: id }), groups: client.subscribe({ kind: "userGroups", spaceId: id }) },
        )
      })
    })
  })

  // Suggestion objects keep their identity while their row and access hold, so the composer's list does not re-render.
  const userCache = new WeakMap<UserRow, Map<string, MentionSuggestion>>()
  const groupCache = new WeakMap<UserGroupRow, Map<string, MentionSuggestion>>()
  const fieldCache = new WeakMap<object, Candidate["fields"]>()

  const userSuggestion = (user: UserRow, source: MentionSource, hasAccess: boolean): MentionSuggestion => {
    let byState = userCache.get(user)
    if (!byState) userCache.set(user, (byState = new Map()))
    const stateKey = `${source}:${hasAccess}`
    let suggestion = byState.get(stateKey)
    if (!suggestion) {
      const name = userDisplayName(user)
      const username = user.username?.trim().replace(/^@+/, "")
      suggestion = {
        id: `user:${user.id}`,
        title: name,
        ...(username ? { subtitle: `@${username}` } : {}),
        avatar: { name, seed: userAvatarSeed(user), ...(user.photoUrl ? { src: user.photoUrl } : {}) },
        item: { kind: "mention", atom: { type: "mention", userId: user.id }, label: mentionLabel(user) },
        mention: { kind: "user", userId: user.id, bot: user.bot === true, source, hasAccess },
      }
      byState.set(stateKey, suggestion)
    }
    return suggestion
  }

  const groupSuggestion = (group: UserGroupRow, hasAccess: boolean): MentionSuggestion => {
    let byState = groupCache.get(group)
    if (!byState) groupCache.set(group, (byState = new Map()))
    const stateKey = String(hasAccess)
    let suggestion = byState.get(stateKey)
    if (!suggestion) {
      suggestion = {
        id: `group:${group.id}`,
        title: group.name,
        subtitle: groupSubtitle(group),
        avatar: { name: group.name, seed: group.name },
        item: { kind: "mention", atom: { type: "groupMention", groupId: group.id }, label: `@${group.name}` },
        mention: { kind: "group", groupId: group.id, hasAccess, memberCount: group.memberCount },
      }
      byState.set(stateKey, suggestion)
    }
    return suggestion
  }

  const fieldsOf = (row: UserRow | UserGroupRow): Candidate["fields"] => {
    let fields = fieldCache.get(row)
    if (!fields) {
      const out: { field: PreparedField; role: FieldRole }[] = []
      const add = (text: string | undefined, priority: number, role: FieldRole) => {
        const field = prepareField(text, priority)
        if (field && !out.some((other) => other.field.normalized === field.normalized)) out.push({ field, role })
      }
      if (row.kind === "user") {
        add(row.username?.trim().replace(/^@+/, ""), 600, "username")
        add(userDisplayName(row), 500, "name")
      } else {
        add(row.name, 500, "name")
        add(row.description, 0, "detail")
      }
      fields = out
      fieldCache.set(row, fields)
    }
    return fields
  }

  const candidates = computed<readonly Candidate[]>(() => {
    const access = participants.access.get()
    const lists = spaceLists.get()
    const memberIds = new Set<UserID>()
    for (const key of lists?.members.list.get() ?? []) {
      const row = store.rowByKey(key).get() as MemberRow | undefined
      if (row?.kind === "member") memberIds.add(row.userId)
    }
    const recent = new Map<UserID, number>()
    for (const id of options.recentSenders?.get() ?? []) if (!recent.has(id)) recent.set(id, recent.size)
    const direct = new Map<UserID, DirectPeer>()
    for (const peer of options.directPeers?.get() ?? []) direct.set(peer.userId, peer)

    const out: Candidate[] = []
    const ids = new Set<UserID>([...access.userIds, ...memberIds, ...direct.keys()])
    ids.delete(viewerId)
    for (const id of ids) {
      const user = store.row("user", id).get()
      if (!user) continue
      const source: MentionSource = access.userIds.has(id) ? "participant" : memberIds.has(id) ? "spaceMember" : "directChat"
      const peer = direct.get(id)
      out.push({
        key: `user:${id}`,
        id,
        hasAccess: source === "participant",
        recentRank: recent.get(id) ?? Number.POSITIVE_INFINITY,
        pinned: peer?.pinned === true,
        lastDirectDate: peer?.lastMessageDate ?? Number.NEGATIVE_INFINITY,
        sortRank: sourceRank[source],
        sortText: normalizeText(userDisplayName(user)),
        offeredWithoutQuery: source !== "directChat",
        fields: fieldsOf(user),
        suggestion: userSuggestion(user, source, source === "participant"),
      })
    }
    for (const key of lists?.groups.list.get() ?? []) {
      const group = store.rowByKey(key).get() as UserGroupRow | undefined
      if (group?.kind !== "userGroup") continue
      const hasAccess = access.groupIds.has(group.id)
      out.push({
        key: `group:${group.id}`,
        id: group.id,
        hasAccess,
        recentRank: Number.POSITIVE_INFINITY,
        pinned: false,
        lastDirectDate: Number.NEGATIVE_INFINITY,
        sortRank: 0,
        sortText: normalizeText(group.name),
        offeredWithoutQuery: true,
        fields: fieldsOf(group),
        suggestion: groupSuggestion(group, hasAccess),
      })
    }
    return out.sort(precedes)
  })

  const rows = (text: string): readonly MentionSuggestion[] => {
    const list = candidates.get()
    const query = prepareQuery(text)
    if (!query) {
      // Punctuation alone matches nothing; an empty query lists everyone offered without one.
      if (text.trim().length > 0) return []
      const out: MentionSuggestion[] = []
      for (const candidate of list) {
        if (!candidate.offeredWithoutQuery) continue
        out.push(candidate.suggestion)
        if (out.length >= limit) break
      }
      return out
    }
    const buckets: MentionSuggestion[][] = Array.from({ length: BUCKETS }, () => [])
    for (const candidate of list) {
      const bucket = bucketOf(query, candidate)
      if (bucket !== undefined) buckets[bucket]?.push(candidate.suggestion)
    }
    return buckets.flat().slice(0, limit)
  }

  return {
    suggest: (trigger) => (trigger.kind === "mention" ? rows(trigger.query) : []),
    rows,
    candidates,
    dispose: () => {
      stopScope()
      const space = spaceLists.peek()
      space?.members.unsubscribe()
      space?.groups.unsubscribe()
      spaceLists.set(undefined)
    },
  }
}

export type { Candidate as MentionCandidate }
