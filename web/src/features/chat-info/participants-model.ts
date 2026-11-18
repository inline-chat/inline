/**
 * Who is in a chat, by the Mac's rules (`ChatParticipantsWithMembersViewModel`):
 *
 * - The list comes from the chat's root: a subthread (a chat with a parent)
 *   inherits its top-level chat's participants. A missing parent or a cycle
 *   ends the chain.
 * - A direct message lists its peer.
 * - A public thread in a space lists the space's members.
 * - Any other chat lists its own participants: group grants first, then
 *   people (the core's `chatParticipants` order).
 *
 * The core leaves these fallbacks to the UI (`client/src/host/README.md`),
 * so this model subscribes to the chain's `chat` rows, then to the right
 * list. It never flashes empty: while the source is being resolved, or while
 * a new source's first answer is on its way, the status is `pending` and the
 * previous list stays; once the core answers, the device's list shows at
 * once even while a server fetch is `loading`.
 *
 * `access` is the effective set of people and groups who can read the chat
 * (`effectiveParticipantAccess`): the shown list's people and groups' members
 * (for a public thread, members who can see public chats), plus the chat's
 * own grants when it inherits. Mentions rank these first and the mention
 * add policy checks against it.
 *
 * Framework-free; one model per chat, disposed by its owner.
 */

import type {
  ChatRow,
  MemberRole,
  MemberRow,
  QueryDescriptor,
  RosterResource,
  Row,
  RowKey,
  UserGroupRow,
  UserRow,
} from "@inline/core-protocol"
import { rowKey } from "@inline/core-protocol"
import type { ChatID, SpaceID, UserID } from "@inline/ids"
import {
  batch,
  browserClock,
  computed,
  effect,
  plainEqual,
  scope,
  signal,
  untracked,
  type Clock,
  type ReadSignal,
  type StoreClient,
  type SubscriptionHandle,
} from "@inline/reactive"
import { userAvatarSeed, userDisplayName } from "@inline/chat-ui"

/** Where a chat's list comes from. `inherited`: from an ancestor, not the chat itself. */
export type ParticipantSource =
  | { readonly kind: "resolving" }
  | { readonly kind: "direct"; readonly chatId: ChatID; readonly peerUserId: UserID; readonly inherited: boolean }
  | { readonly kind: "space"; readonly chatId: ChatID; readonly spaceId: SpaceID; readonly inherited: boolean }
  | { readonly kind: "chat"; readonly chatId: ChatID; readonly spaceId?: SpaceID; readonly inherited: boolean }

export type ParticipantAvatar = { readonly name: string; readonly seed: string; readonly src?: string }

/** One row of the list, ready to draw. */
export type ParticipantItem =
  | {
      readonly kind: "user"
      readonly key: RowKey
      readonly userId: UserID
      readonly name: string
      /** Without `@`. */
      readonly username?: string
      readonly bot: boolean
      /** The signed-in user ("You"). */
      readonly isViewer: boolean
      /** Space members only, as the Mac's member list labels them: owners and admins. */
      readonly role?: Exclude<MemberRole, "member">
      /** A space member who sees only the private threads they were added to ("Restricted"). */
      readonly restricted: boolean
      readonly avatar: ParticipantAvatar
    }
  | {
      readonly kind: "group"
      readonly key: RowKey
      readonly groupId: string
      readonly name: string
      /** "Design team - 3 people", or "3 people" (the Mac's group row). */
      readonly subtitle: string
      readonly memberCount: number
      readonly avatar: ParticipantAvatar
    }

/**
 * - `pending`: nothing to show yet (the source is being resolved, or the
 *   core has not answered). Show nothing, not "no participants".
 * - `loading`: the device's list is shown and a server fetch is running.
 * - `ready`: the list is current.
 * - `failed`: the last fetch failed; the list is what the device has.
 */
export type ParticipantsStatus = "pending" | "loading" | "ready" | "failed"

export type ParticipantAccess = { readonly userIds: ReadonlySet<UserID>; readonly groupIds: ReadonlySet<string> }

export type ParticipantsModel = {
  readonly chatId: ChatID
  /** The chat's own row, once in the store. */
  readonly chat: ReadSignal<ChatRow | undefined>
  /** The top of the chat's chain (itself when it has no parent). */
  readonly root: ReadSignal<ChatRow | undefined>
  readonly source: ReadSignal<ParticipantSource>
  /** The space of the chat's root, for space members and user groups. */
  readonly spaceId: ReadSignal<SpaceID | undefined>
  /** Row keys in the list's order. A list view observes only this. */
  readonly ids: ReadSignal<readonly RowKey[]>
  /** One cached computed per key; keeps its identity while what the row shows holds. */
  member(key: RowKey): ReadSignal<ParticipantItem | undefined>
  readonly status: ReadSignal<ParticipantsStatus>
  /** The device holds the whole list (the core's `roster.complete`; always for a direct message). */
  readonly complete: ReadSignal<boolean>
  /** True only when the list is answered and empty ("No access grants found in this chat."). */
  readonly showEmpty: ReadSignal<boolean>
  readonly counts: ReadSignal<{ readonly people: number; readonly groups: number }>
  readonly access: ReadSignal<ParticipantAccess>
  dispose(): void
}

export type ParticipantsModelOptions = {
  readonly client: StoreClient
  readonly chatId: ChatID
  readonly viewerId: UserID
  /** For the wait on a parent chat that is not in the store. Default: the browser clock. */
  readonly clock?: Clock
  /** How long to wait for a missing chat row before ending the chain where it is (Mac rule). Default 1 s. */
  readonly missingChatWaitMs?: number
}

type Active = { readonly query: QueryDescriptor; readonly handle: SubscriptionHandle }

const roster = (handle: SubscriptionHandle | undefined): RosterResource | undefined => {
  const value = handle?.resource.get()
  return value?.kind === "roster" ? value : undefined
}

const sameSet = <T>(a: ReadonlySet<T>, b: ReadonlySet<T>) => a.size === b.size && [...a].every((value) => b.has(value))

const groupSubtitle = (group: UserGroupRow): string => {
  const count = group.memberCount === 1 ? "1 person" : `${group.memberCount} people`
  const description = group.description?.trim()
  return description ? `${description} - ${count}` : count
}

const queryFor = (source: ParticipantSource): QueryDescriptor | undefined => {
  switch (source.kind) {
    case "resolving":
      return undefined
    case "direct":
      return { kind: "user", userId: source.peerUserId }
    case "space":
      return { kind: "spaceMembers", spaceId: source.spaceId }
    case "chat":
      return { kind: "chatParticipants", chatId: source.chatId }
  }
}

export const createParticipantsModel = (options: ParticipantsModelOptions): ParticipantsModel => {
  const { client, chatId, viewerId } = options
  const store = client.store
  const clock = options.clock ?? browserClock()
  const waitMs = options.missingChatWaitMs ?? 1_000

  // --- The chain: the chat and its ancestors, as far as the store has them.
  const chain = computed(
    () => {
      const rows: ChatRow[] = []
      const ids: ChatID[] = []
      let id: ChatID | undefined = chatId
      let missing: ChatID | undefined
      while (id !== undefined && !ids.includes(id)) {
        ids.push(id)
        const row = store.row("chat", id).get()
        if (!row) {
          missing = id
          break
        }
        rows.push(row)
        id = row.parentChatId
      }
      return { rows, ids, missing }
    },
    { equals: (a, b) => a.missing === b.missing && a.rows.length === b.rows.length && a.rows.every((row, i) => row === b.rows[i]) && plainEqual(a.ids, b.ids) },
  )
  /** The chat whose missing row was waited for long enough. */
  const gaveUpOn = signal<ChatID | undefined>(undefined)

  const source = computed<ParticipantSource>(
    () => {
      const { rows, missing } = chain.get()
      if (missing !== undefined && gaveUpOn.get() !== missing) return { kind: "resolving" }
      const root = rows[rows.length - 1]
      if (!root) return { kind: "chat", chatId, inherited: false }
      const inherited = root.id !== chatId
      if (root.peerUserId !== undefined) return { kind: "direct", chatId: root.id, peerUserId: root.peerUserId, inherited }
      if (root.spaceId !== undefined && root.isPublic === true) return { kind: "space", chatId: root.id, spaceId: root.spaceId, inherited }
      return { kind: "chat", chatId: root.id, inherited, ...(root.spaceId !== undefined ? { spaceId: root.spaceId } : {}) }
    },
    { equals: plainEqual },
  )

  const chat = computed(() => chain.get().rows[0])
  const root = computed(() => {
    const rows = chain.get().rows
    return rows[rows.length - 1]
  })
  const spaceId = computed(() => root.get()?.spaceId)

  // --- Subscriptions, owned by effects in one scope.
  const chatSubs = new Map<ChatID, SubscriptionHandle>()
  const current = signal<Active | undefined>(undefined)
  const previous = signal<Active | undefined>(undefined)
  const ownGrants = signal<SubscriptionHandle | undefined>(undefined)

  const answered = (active: Active | undefined): boolean => {
    if (!active) return false
    if (active.query.kind === "user") return true
    return active.handle.resource.get() !== undefined
  }

  const stopScope = scope(() => {
    // Keep a `chat` subscription for every chat of the chain, and time out a missing one.
    effect(() => {
      const { ids, missing } = chain.get()
      untracked(() => {
        for (const id of ids) if (!chatSubs.has(id)) chatSubs.set(id, client.subscribe({ kind: "chat", chatId: id }))
        for (const [id, handle] of chatSubs) {
          if (ids.includes(id)) continue
          handle.unsubscribe()
          chatSubs.delete(id)
        }
      })
      if (missing === undefined) return
      const timer = clock.setTimeout(() => gaveUpOn.set(missing), waitMs)
      return () => clock.clearTimeout(timer)
    })

    // Subscribe to the source's list; hold the previous list until the new one is answered.
    effect(() => {
      const query = queryFor(source.get())
      if (!query) return
      untracked(() => {
        const now = current.peek()
        if (now && plainEqual(now.query, query)) return
        previous.peek()?.handle.unsubscribe()
        const next = { query, handle: client.subscribe(query) }
        batch(() => {
          previous.set(now)
          current.set(next)
        })
      })
    })
    effect(() => {
      const held = previous.get()
      if (!held || !answered(current.get())) return
      untracked(() => {
        held.handle.unsubscribe()
        previous.set(undefined)
      })
    })

    // The chat's own grants count for access when its list comes from elsewhere.
    effect(() => {
      const src = source.get()
      const own = chat.get()
      const wanted = src.kind !== "resolving" && own !== undefined && own.peerUserId === undefined && (src.inherited || src.kind === "space")
      untracked(() => {
        const handle = ownGrants.peek()
        if (wanted && !handle) ownGrants.set(client.subscribe({ kind: "chatParticipants", chatId }))
        if (!wanted && handle) {
          handle.unsubscribe()
          ownGrants.set(undefined)
        }
      })
    })
  })

  /** The subscription whose list is shown: the new one once answered, else the held one. */
  const shown = computed(() => {
    const now = current.get()
    const held = previous.get()
    return held && !answered(now) ? held : now
  })

  const ids = computed<readonly RowKey[]>(
    () => {
      const active = shown.get()
      if (!active) return []
      if (active.query.kind === "user") return [rowKey("user", active.query.userId)]
      return active.handle.list.get()
    },
    { equals: plainEqual },
  )

  const status = computed<ParticipantsStatus>(() => {
    if (source.get().kind === "resolving") return shown.get() ? "loading" : "pending"
    const active = shown.get()
    if (!active) return "pending"
    if (active.query.kind === "user") return "ready"
    const value = roster(active.handle)
    if (!value) return "pending"
    if (value.loading) return "loading"
    if (value.failed) return "failed"
    return "ready"
  })

  const complete = computed(() => {
    const active = shown.get()
    if (!active) return false
    if (active.query.kind === "user") return true
    return roster(active.handle)?.complete === true
  })

  const showEmpty = computed(() => {
    const value = status.get()
    return (value === "ready" || value === "failed") && ids.get().length === 0
  })

  const rowOf = (key: RowKey): Row | undefined => store.rowByKey(key).get()

  const counts = computed(
    () => {
      let people = 0
      let groups = 0
      for (const key of ids.get()) {
        if (key.startsWith("userGroup:")) groups++
        else people++
      }
      return { people, groups }
    },
    { equals: plainEqual },
  )

  const access = computed<ParticipantAccess>(
    () => {
      const userIds = new Set<UserID>()
      const groupIds = new Set<string>()
      const publicMembersOnly = source.get().kind === "space"
      const collect = (keys: readonly RowKey[], fromPublicSpace: boolean) => {
        for (const key of keys) {
          const row = rowOf(key)
          if (!row) continue
          if (row.kind === "user") userIds.add(row.id)
          else if (row.kind === "member") {
            if (!fromPublicSpace || row.canAccessPublicChats !== false) userIds.add(row.userId)
          } else if (row.kind === "userGroup") {
            groupIds.add(row.id)
            for (const id of row.userIds) userIds.add(id)
          }
        }
      }
      collect(ids.get(), publicMembersOnly)
      const own = ownGrants.get()
      if (own) collect(own.list.get(), false)
      return { userIds, groupIds }
    },
    { equals: (a, b) => sameSet(a.userIds, b.userIds) && sameSet(a.groupIds, b.groupIds) },
  )

  const members = new Map<RowKey, ReadSignal<ParticipantItem | undefined>>()
  const userItem = (key: RowKey, user: UserRow | undefined, userId: UserID, member?: MemberRow): ParticipantItem => {
    const name = userDisplayName(user)
    const username = user?.username?.trim().replace(/^@+/, "")
    const role = member?.role === "owner" || member?.role === "admin" ? member.role : undefined
    return {
      kind: "user",
      key,
      userId,
      name,
      ...(username ? { username } : {}),
      bot: user?.bot === true,
      isViewer: userId === viewerId,
      ...(role ? { role } : {}),
      restricted: member?.spaceId !== undefined && member.role === "member" && member.canAccessPublicChats === false,
      avatar: { name, seed: userAvatarSeed(user), ...(user?.photoUrl ? { src: user.photoUrl } : {}) },
    }
  }

  return {
    chatId,
    chat,
    root,
    source,
    spaceId,
    ids,
    member: (key) => {
      let cached = members.get(key)
      if (!cached) {
        cached = computed<ParticipantItem | undefined>(
          () => {
            const row = rowOf(key)
            if (!row) return undefined
            switch (row.kind) {
              case "user":
                return userItem(key, row, row.id)
              case "member":
                return userItem(key, store.row("user", row.userId).get(), row.userId, row)
              case "userGroup":
                return {
                  kind: "group",
                  key,
                  groupId: row.id,
                  name: row.name,
                  subtitle: groupSubtitle(row),
                  memberCount: row.memberCount,
                  avatar: { name: row.name, seed: row.name },
                }
              default:
                return undefined
            }
          },
          { equals: plainEqual },
        )
        members.set(key, cached)
      }
      return cached
    },
    status,
    complete,
    showEmpty,
    counts,
    access,
    dispose: () => {
      stopScope()
      for (const handle of chatSubs.values()) handle.unsubscribe()
      chatSubs.clear()
      current.peek()?.handle.unsubscribe()
      previous.peek()?.handle.unsubscribe()
      ownGrants.peek()?.unsubscribe()
      members.clear()
    },
  }
}
