/**
 * A scripted core for the chat info, mention and typing models, their tests
 * and the lab. It speaks the `CoreEndpoint` contract over the scripted
 * endpoint from `@inline/reactive/testing` and answers the queries these
 * models use (`chat`, `user`, `chatParticipants`, `spaceMembers`,
 * `userGroups`, `composeActions`, `chatMedia`) from data the test or lab
 * sets, ordered as the core orders them. Participant intents change the
 * chat's list when they are applied (not when refused). Intents are recorded and settled by a mode the
 * caller picks, so every outcome can be produced.
 *
 * Not a model of the server: it publishes whatever it holds, at once or when
 * told (`autoAnswer: false`, then `answer()`).
 */

import type {
  ChatMediaFilter,
  ChatMediaResource,
  ChatRow,
  Command,
  ComposeActivity,
  CoreEndpoint,
  DialogRow,
  Intent,
  IntentRejection,
  IntentResult,
  MemberRole,
  MemberRow,
  MessageRow,
  QueryDescriptor,
  ResourceValue,
  Row,
  RowKey,
  SubId,
  TxId,
  UserGroupRow,
  UserRow,
} from "@inline/core-protocol"
import { memberRowId, rowKey, rowKeyOf } from "@inline/core-protocol"
import type { ChatID, SpaceID, UserID } from "@inline/ids"
import { createScheduler, createStoreClient, manualTime, plainEqual, type ManualTime, type StoreClient } from "@inline/reactive"
import { scriptedEndpoint, type ScriptedEndpoint } from "@inline/reactive/testing"
import { userDisplayName } from "@inline/chat-ui"

export type RosterState = { readonly complete: boolean; readonly loading: boolean; readonly failed?: boolean }

export type SpaceMemberInput = {
  readonly userId: UserID
  readonly role?: MemberRole
  readonly canAccessPublicChats?: boolean
  /** Seconds since the epoch. */
  readonly date?: number
}

/**
 * How the fake settles an intent it does not handle specially:
 * - `confirm`: accepted and confirmed in one patch (rows applied).
 * - `hold`: accepted (rows applied); `settleHeld` finishes it later.
 * - `reject`: rejected by the server, nothing applied.
 * - `storageFull`, `offline`, `unavailable`: rejected by the core with that reason.
 * - `uncertain`: accepted, then uncertain.
 */
export type IntentMode = "confirm" | "hold" | "reject" | "storageFull" | "offline" | "unavailable" | "uncertain"

type Published = {
  keys: readonly RowKey[]
  resource?: ResourceValue
}

const compareIds = (a: string, b: string): number => (a.length !== b.length ? a.length - b.length : a < b ? -1 : a > b ? 1 : 0)

export class FakeChatCore {
  readonly scripted: ScriptedEndpoint
  readonly endpoint: CoreEndpoint
  /** Answer subscriptions as soon as they arrive. False: wait for `answer()`. */
  autoAnswer: boolean
  intentMode: IntentMode = "confirm"
  readonly me: UserID

  readonly #users = new Map<UserID, UserRow>()
  readonly #chats = new Map<ChatID, ChatRow>()
  readonly #dialogs = new Map<ChatID, DialogRow>()
  readonly #participants = new Map<ChatID, { userIds: UserID[]; groupIds: string[]; roster: RosterState }>()
  readonly #members = new Map<SpaceID, { members: SpaceMemberInput[]; roster: RosterState }>()
  readonly #groups = new Map<string, UserGroupRow>()
  #compose: ComposeActivity[] = []
  readonly #chatMedia = new Map<string, { rows: MessageRow[]; resource: Omit<ChatMediaResource, "kind"> }>()
  /** `ensure` commands, in order. */
  readonly ensures: { query: QueryDescriptor | undefined; range: Extract<Command, { kind: "ensure" }>["range"] }[] = []

  readonly #subs = new Map<SubId, QueryDescriptor>()
  readonly #answered = new Set<SubId>()
  readonly #published = new Map<SubId, Published>()
  /** Row objects the context holds, by key: only changed objects are sent again. */
  readonly #sent = new Map<RowKey, Row>()
  readonly #held = new Map<TxId, Intent>()
  readonly intents: { tx: TxId; intent: Intent }[] = []

  constructor(options: { me: UserID; autoAnswer?: boolean }) {
    this.me = options.me
    this.autoAnswer = options.autoAnswer ?? true
    this.scripted = scriptedEndpoint()
    const scripted = this.scripted
    this.endpoint = {
      // Commands are recorded at once and answered in a microtask, as a core
      // in a worker answers after a hop. (A synchronous answer to a subscribe
      // posted from an effect at the end of a frame would be stranded: see
      // the README's "Needs from others".)
      post: (command) => {
        scripted.post(command)
        this.#record(command)
        queueMicrotask(() => this.#onCommand(command))
      },
      subscribe: (listener) => scripted.subscribe(listener),
      close: () => scripted.close(),
    }
  }

  // MARK: Data

  setUsers(rows: readonly UserRow[]): void {
    for (const row of rows) this.#users.set(row.id, row)
    this.publish()
  }

  setUser(row: UserRow): void {
    this.setUsers([row])
  }

  user(id: UserID): UserRow | undefined {
    return this.#users.get(id)
  }

  setChat(row: ChatRow): void {
    this.#chats.set(row.id, row)
    this.publish()
  }

  chat(id: ChatID): ChatRow | undefined {
    return this.#chats.get(id)
  }

  setDialog(row: DialogRow): void {
    this.#dialogs.set(row.chatId, row)
    this.publish()
  }

  dialog(chatId: ChatID): DialogRow | undefined {
    return this.#dialogs.get(chatId)
  }

  setParticipants(chatId: ChatID, userIds: readonly UserID[], options: Partial<RosterState> & { groupIds?: readonly string[] } = {}): void {
    this.#participants.set(chatId, {
      userIds: [...userIds],
      groupIds: [...(options.groupIds ?? this.#participants.get(chatId)?.groupIds ?? [])],
      roster: { complete: options.complete ?? true, loading: options.loading ?? false, ...(options.failed ? { failed: true } : {}) },
    })
    this.publish()
  }

  setSpaceMembers(spaceId: SpaceID, members: readonly SpaceMemberInput[], options: Partial<RosterState> = {}): void {
    this.#members.set(spaceId, {
      members: [...members],
      roster: { complete: options.complete ?? true, loading: options.loading ?? false, ...(options.failed ? { failed: true } : {}) },
    })
    this.publish()
  }

  setGroups(rows: readonly UserGroupRow[]): void {
    for (const row of rows) this.#groups.set(row.id, row)
    this.publish()
  }

  /** What a `chatMedia(chatId, filter)` subscription lists (newest first) and its resource. */
  setChatMedia(chatId: ChatID, filter: ChatMediaFilter, rows: readonly MessageRow[], resource: Partial<Omit<ChatMediaResource, "kind">> = {}): void {
    this.#chatMedia.set(`${chatId}:${filter}`, {
      rows: [...rows],
      resource: { loading: resource.loading ?? false, hasMore: resource.hasMore ?? false, fetched: resource.fetched ?? true, ...(resource.failed ? { failed: true } : {}) },
    })
    this.publish()
  }

  chatMedia(chatId: ChatID, filter: ChatMediaFilter): { rows: MessageRow[]; resource: Omit<ChatMediaResource, "kind"> } | undefined {
    return this.#chatMedia.get(`${chatId}:${filter}`)
  }

  participantIds(chatId: ChatID): readonly UserID[] {
    return this.#participants.get(chatId)?.userIds ?? []
  }

  setCompose(activities: readonly ComposeActivity[]): void {
    this.#compose = [...activities]
    this.publish()
  }

  // MARK: Subscriptions

  /** Live subscriptions. */
  subs(): QueryDescriptor[] {
    return [...this.#subs.values()]
  }

  subsOf<K extends QueryDescriptor["kind"]>(kind: K): Extract<QueryDescriptor, { kind: K }>[] {
    return this.subs().filter((query) => query.kind === kind) as never
  }

  /** Answer every subscription that has not been answered (with `autoAnswer: false`). */
  answer(match?: (query: QueryDescriptor) => boolean): void {
    for (const [sub, query] of this.#subs) {
      if (this.#answered.has(sub)) continue
      if (match && !match(query)) continue
      this.#answered.add(sub)
    }
    this.publish()
  }

  // MARK: Intents

  /** Finish every held intent. */
  settleHeld(status: "confirmed" | "rejected" | "uncertain", reason?: IntentRejection): void {
    const settled: IntentResult[] = []
    for (const [tx] of this.#held) {
      settled.push({ tx, status, ...(status === "rejected" ? { reason: reason ?? "server" } : {}) })
    }
    this.#held.clear()
    this.publish(settled)
  }

  /** Intents of one kind, in order. */
  intentsOf<K extends Intent["kind"]>(kind: K): Extract<Intent, { kind: K }>[] {
    return this.intents.map((entry) => entry.intent).filter((intent) => intent.kind === kind) as never
  }

  // MARK: Publishing

  /** Send one patch with every change the context does not have yet, plus `settled`. */
  publish(settled: readonly IntentResult[] = []): void {
    const rows: Row[] = []
    const lists: { sub: SubId; op: "replace"; keys: RowKey[] }[] = []
    const resources: { sub: SubId; value: ResourceValue }[] = []
    const addRow = (row: Row) => {
      const key = rowKeyOf(row)
      if (this.#sent.get(key) === row) return
      this.#sent.set(key, row)
      rows.push(row)
    }
    for (const [sub, query] of this.#subs) {
      if (!this.#answered.has(sub)) continue
      const result = this.#compute(query)
      for (const row of result.rows) addRow(row)
      const previous = this.#published.get(sub)
      if (!previous || !plainEqual(previous.keys, result.keys)) lists.push({ sub, op: "replace", keys: [...result.keys] })
      if (result.resource && (!previous || !plainEqual(previous.resource, result.resource))) {
        resources.push({ sub, value: result.resource })
      }
      this.#published.set(sub, { keys: result.keys, ...(result.resource ? { resource: result.resource } : {}) })
    }
    if (rows.length === 0 && lists.length === 0 && resources.length === 0 && settled.length === 0) return
    this.scripted.patch({ rows: rows.map((row) => ({ op: "upsert" as const, row })), lists, resources, settled: [...settled] })
  }

  #compute(query: QueryDescriptor): { keys: RowKey[]; rows: Row[]; resource?: ResourceValue } {
    switch (query.kind) {
      case "chat": {
        const chat = this.#chats.get(query.chatId)
        return chat ? { keys: [rowKeyOf(chat)], rows: [chat] } : { keys: [], rows: [] }
      }
      case "user": {
        const user = this.#users.get(query.userId)
        return user ? { keys: [rowKeyOf(user)], rows: [user] } : { keys: [], rows: [] }
      }
      case "chatParticipants":
        return this.#chatParticipants(query.chatId)
      case "spaceMembers":
        return this.#spaceMembers(query.spaceId)
      case "userGroups": {
        const groups = [...this.#groups.values()]
          .filter((group) => group.spaceId === query.spaceId)
          .sort((a, b) => a.name.localeCompare(b.name) || compareIds(a.id, b.id))
        return { keys: groups.map(rowKeyOf), rows: groups }
      }
      case "sidebar": {
        // Every dialog, with its chat: enough for models that read a dialog row.
        const dialogs = [...this.#dialogs.values()].filter((row) => (query.mode === "archived") === row.archived || query.mode === "all")
        const rows: Row[] = []
        for (const dialog of dialogs) {
          rows.push(dialog)
          const chat = this.#chats.get(dialog.chatId)
          if (chat) rows.push(chat)
        }
        return { keys: dialogs.map(rowKeyOf), rows }
      }
      case "chatMedia": {
        const entry = this.#chatMedia.get(`${query.chatId}:${query.filter}`)
        if (!entry) return { keys: [], rows: [] }
        const rows: Row[] = []
        for (const message of entry.rows) {
          rows.push(message)
          const sender = this.#users.get(message.fromId)
          if (sender) rows.push(sender)
        }
        return { keys: entry.rows.map(rowKeyOf), rows, resource: { kind: "chatMedia", ...entry.resource } }
      }
      case "composeActions": {
        const activities = this.#compose.filter((entry) => !query.chatId || entry.chatId === query.chatId)
        const users = activities.flatMap((entry) => {
          const user = this.#users.get(entry.userId)
          return user ? [user] : []
        })
        return { keys: users.map(rowKeyOf), rows: users, resource: { kind: "compose", activities } }
      }
      default:
        return { keys: [], rows: [] }
    }
  }

  #chatParticipants(chatId: ChatID): { keys: RowKey[]; rows: Row[]; resource: ResourceValue } {
    const entry = this.#participants.get(chatId)
    const roster = entry?.roster ?? { complete: false, loading: true }
    const rows: Row[] = []
    const keys: RowKey[] = []
    const groups = (entry?.groupIds ?? [])
      .flatMap((id) => {
        const group = this.#groups.get(id)
        return group ? [group] : []
      })
      .sort((a, b) => a.name.localeCompare(b.name) || compareIds(a.id, b.id))
    for (const group of groups) {
      rows.push(group)
      keys.push(rowKeyOf(group))
    }
    const people = (entry?.userIds ?? [])
      .map((userId) => ({ userId, name: userDisplayName(this.#users.get(userId)).toLowerCase() }))
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : compareIds(a.userId, b.userId)))
    for (const { userId } of people) {
      const member = this.#memberRow({ chatId }, userId, {})
      rows.push(member)
      keys.push(rowKeyOf(member))
      const user = this.#users.get(userId)
      if (user) rows.push(user)
    }
    return { keys, rows, resource: { kind: "roster", complete: roster.complete, loading: roster.loading, ...(roster.failed ? { failed: true } : {}) } }
  }

  #spaceMembers(spaceId: SpaceID): { keys: RowKey[]; rows: Row[]; resource: ResourceValue } {
    const entry = this.#members.get(spaceId)
    const roster = entry?.roster ?? { complete: false, loading: true }
    const members = [...(entry?.members ?? [])].sort((a, b) => {
      if (a.userId === this.me && b.userId !== this.me) return -1
      if (b.userId === this.me && a.userId !== this.me) return 1
      if ((a.date ?? 0) !== (b.date ?? 0)) return (a.date ?? 0) - (b.date ?? 0)
      return compareIds(a.userId, b.userId)
    })
    const rows: Row[] = []
    const keys: RowKey[] = []
    for (const member of members) {
      const row = this.#memberRow({ spaceId }, member.userId, member)
      rows.push(row)
      keys.push(rowKeyOf(row))
      const user = this.#users.get(member.userId)
      if (user) rows.push(user)
    }
    return { keys, rows, resource: { kind: "roster", complete: roster.complete, loading: roster.loading, ...(roster.failed ? { failed: true } : {}) } }
  }

  /** Member rows keep their object while their content holds, so unchanged members are not re-sent. */
  readonly #memberRows = new Map<string, MemberRow>()
  #memberRow(scope: { spaceId: SpaceID } | { chatId: ChatID }, userId: UserID, input: Partial<SpaceMemberInput>): MemberRow {
    const id = memberRowId(scope, userId)
    const next: MemberRow = {
      kind: "member",
      id,
      userId,
      ...scope,
      ...(input.role ? { role: input.role } : {}),
      ...(input.canAccessPublicChats !== undefined ? { canAccessPublicChats: input.canAccessPublicChats } : {}),
      ...(input.date !== undefined ? { date: input.date } : {}),
    }
    const previous = this.#memberRows.get(id)
    if (previous && plainEqual(previous, next)) return previous
    this.#memberRows.set(id, next)
    return next
  }

  // MARK: Commands

  #record(command: Command): void {
    switch (command.kind) {
      case "subscribe":
        this.#subs.set(command.sub, command.query)
        return
      case "unsubscribe":
        this.#subs.delete(command.sub)
        this.#answered.delete(command.sub)
        this.#published.delete(command.sub)
        return
      case "intent":
        this.intents.push({ tx: command.tx, intent: command.intent })
        return
      case "ensure":
        this.ensures.push({ query: this.#subs.get(command.sub), range: command.range })
        return
      default:
        return
    }
  }

  #onCommand(command: Command): void {
    switch (command.kind) {
      case "subscribe":
        if (!this.#subs.has(command.sub)) return
        if (this.autoAnswer) this.#answered.add(command.sub)
        this.publish()
        return
      case "intent":
        this.#onIntent(command.tx, command.intent)
        return
      default:
        return
    }
  }

  #onIntent(tx: TxId, intent: Intent): void {
    if (intent.kind === "composeAction") {
      this.publish([{ tx, status: "confirmed" }])
      return
    }
    const mode = this.intentMode
    if (mode === "storageFull" || mode === "offline" || mode === "unavailable") {
      this.publish([{ tx, status: "rejected", reason: mode }])
      return
    }
    if (mode === "reject") {
      this.publish([{ tx, status: "accepted" }])
      this.publish([{ tx, status: "rejected", reason: "server" }])
      return
    }
    this.#apply(intent)
    if (mode === "confirm") {
      this.publish([
        { tx, status: "accepted" },
        { tx, status: "confirmed" },
      ])
      return
    }
    this.publish([{ tx, status: "accepted" }])
    if (mode === "uncertain") {
      this.publish([{ tx, status: "uncertain" }])
      return
    }
    this.#held.set(tx, intent)
  }

  #apply(intent: Intent): void {
    const update = (chatId: ChatID, patch: Partial<DialogRow>) => {
      const dialog = this.#dialogs.get(chatId)
      if (dialog) this.#dialogs.set(chatId, { ...dialog, ...patch })
    }
    switch (intent.kind) {
      case "setDialogNotifications": {
        const dialog = this.#dialogs.get(intent.chatId)
        if (!dialog) return
        const { notificationMode: _, ...rest } = dialog
        this.#dialogs.set(intent.chatId, intent.mode === "default" ? rest : { ...rest, notificationMode: intent.mode })
        return
      }
      case "setDialogFollow": {
        const dialog = this.#dialogs.get(intent.chatId)
        if (!dialog) return
        const { followMode: _, ...rest } = dialog
        this.#dialogs.set(intent.chatId, intent.mode === "relevance" ? rest : { ...rest, followMode: intent.mode })
        return
      }
      case "setDialogPinned":
        update(intent.chatId, { pinned: intent.pinned })
        return
      case "setDialogArchived":
        update(intent.chatId, { archived: intent.archived })
        return
      case "markUnread":
        update(intent.chatId, { unreadMark: true })
        return
      case "addChatParticipants": {
        const entry = this.#participants.get(intent.chatId) ?? { userIds: [], groupIds: [], roster: { complete: true, loading: false } }
        this.#participants.set(intent.chatId, {
          ...entry,
          userIds: [...new Set([...entry.userIds, ...intent.userIds])],
          groupIds: [...new Set([...entry.groupIds, ...(intent.groupIds ?? [])])],
        })
        return
      }
      case "removeChatParticipant": {
        const entry = this.#participants.get(intent.chatId)
        if (!entry) return
        this.#participants.set(intent.chatId, {
          ...entry,
          userIds: entry.userIds.filter((id) => id !== intent.userId),
          groupIds: entry.groupIds.filter((id) => id !== intent.groupId),
        })
        return
      }
      default:
        return
    }
  }
}

/** The row key of a user, for tests. */
export const userKey = (id: UserID): RowKey => rowKey("user", id)

export type TestHarness = {
  readonly core: FakeChatCore
  readonly client: StoreClient
  readonly time: ManualTime
  /** Apply what the core delivered (the frame lane), then let promises settle. */
  flush(): Promise<void>
  dispose(): void
}

/** A store client over a `FakeChatCore` with manual time, for tests. */
export const testHarness = (options: { me: UserID; autoAnswer?: boolean }): TestHarness => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const core = new FakeChatCore(options)
  const client = createStoreClient({ endpoint: core.endpoint, scheduler })
  return {
    core,
    client,
    time,
    flush: async () => {
      // Frames until the core has nothing more to deliver (a model may subscribe in answer to a patch).
      for (let round = 0; round < 20; round++) {
        time.frame()
        for (let i = 0; i < 8; i++) await Promise.resolve()
        if (time.pendingFrames() === 0) break
      }
    },
    dispose: () => {
      client.dispose()
      core.endpoint.close()
    },
  }
}
