/**
 * Materialization of one query against the committed view of the replica
 * (see view.ts). Each query returns its rows, its ordered list, its resource
 * and the dependencies that decide whether a later change can affect it.
 */
import {
  localMedia,
  rowKeyOf,
  type ChatMediaFilter,
  type ComposeActivity,
  type CoreResource,
  type QueryDescriptor,
  type MessageRow,
  type ResourceValue,
  type Row,
  type RowKey,
  type TxId,
  type WindowResource,
} from "@inline/core-protocol"
import { messageId, type ChatID, type MessageID, type UserID } from "@inline/ids"
import type { DbResidentChange } from "../database"
import { compareMessagesByWindow } from "../database/message-window"
import {
  DbObjectKind,
  messageDraftKey,
  messageKey,
  type Chat,
  type Dialog,
  type Message,
  type MessageDraft,
} from "../database/models"
import type { ReplicaView } from "./view"
import {
  certifiedRangeAt,
  coverageRanges,
  windowEdges,
} from "../database/history-coverage"
import {
  chatRow,
  dialogIdForChat,
  dialogRow,
  draftRow,
  isServerMessageId,
  messageRow,
  spaceRow,
  userRow,
} from "./rows"
import { sortSidebar, type SidebarEntry } from "./sidebar"
import { chatMediaMatches } from "./chat-media"
import {
  compareFolders,
  compareGroups,
  compareMembers,
  compareParticipants,
  compareSpaces,
  displayName,
  folderRow,
  fullSpaceRow,
  participantRow,
  settingsRow,
  spaceMemberRow,
  userGroupRow,
} from "./membership"

/** What the materializer needs from a running account core. */
export type QueryAccount = {
  /** Committed state only. */
  readonly view: ReplicaView
  readonly userId: UserID
  /** Message keys in a chat's window (window membership is memory-only). */
  windowKeys(chatId: ChatID): readonly string[]
  /** Whether the chat's window reaches the chat's last message. */
  windowAtLatest(chatId: ChatID): boolean
  /** The session's client key for a message sent from this device, if any. */
  clientKeyFor(message: Message): string | undefined
  /**
   * Window state the replica does not track: what is loading, and whether an
   * older load found nothing below the window.
   */
  windowState(chatId: ChatID): Pick<WindowResource, "loading"> & {
    olderExhausted?: boolean
  }
  /** The draft for a chat, and the replica key it lives under. */
  draftFor(chatId: ChatID): { key: string; draft: MessageDraft | undefined }
  /**
   * Keys of the `newMessages` feed after a subscription's start, oldest
   * first. Absent: the account has no feed (the list stays empty).
   */
  newMessages?(since: number): readonly string[]
  /**
   * A query needed these messages and they are not resident: the account
   * may read them from disk (once); their arrival recomputes the query.
   */
  wantMessages?(keys: readonly string[]): void
  /** Fetch state of a chat's participants or a space's members. */
  roster?(scope: "chat" | "space", id: string): { loading: boolean; failed: boolean }
  /** The resource of a subscription the host answers itself (media, search), by its handle. */
  handleResource?(handle: number): ResourceValue | undefined
  /** Live compose activity in one chat or every chat. */
  composeActivities?(chatId?: ChatID): readonly ComposeActivity[]
  /** A media send's attachment, by the message's random ID (for `MessageRow.upload`). */
  localUpload?(message: Message): MessageRow["upload"]
  /** The UI's transaction ID of a send from this device still in the outbox (`MessageRow.tx`). */
  sendTx?(message: Message): TxId | undefined
  /** A `chatMedia` subscription's server pages and paging state, by its handle. */
  chatMediaState?(handle: number):
    | { listedKeys: ReadonlySet<string>; resource: Extract<ResourceValue, { kind: "chatMedia" }> }
    | undefined
}

export type QueryEnv = {
  core: CoreResource
  /** Null while signed out or starting: queries other than `core` are empty. */
  account: QueryAccount | null
}

/** Per-subscription facts captured when it opened. */
export type SubscriptionFacts = {
  /** The read boundary at open time, for `chatWindow`. */
  unreadBoundary?: MessageID
  /** The descriptor failed validation; the subscription stays empty. */
  invalid?: boolean
  /** For `newMessages`: the feed sequence the subscription started at. */
  since?: number
  /** For queries the host answers itself (media, search): the handle of their state. */
  handle?: number
}

export type QueryDeps = {
  /** `${DbObjectKind}:${id}` of every object read by ID. */
  refs: Set<string>
  /** Kinds where any change can affect the result. */
  kinds: Set<DbObjectKind>
  /** Chats where any message change can affect the result. */
  messageChats: Set<ChatID>
  /** Whether host state (phase, connection, storage) feeds the result. */
  core: boolean
}

export type QueryResult = {
  /** Every row the subscription holds: list rows and the rows they need. */
  rows: Row[]
  /** The ordered list, for list queries. */
  keys?: RowKey[]
  resource?: ResourceValue
  deps: QueryDeps
}

export const depRef = (kind: DbObjectKind, id: string | number) => `${kind}:${id}`

const emptyDeps = (): QueryDeps => ({
  refs: new Set(),
  kinds: new Set(),
  messageChats: new Set(),
  core: false,
})

/** The chat ID of a message key (`${chatId}:${messageId}`). */
export const chatIdOfMessageKey = (key: string): ChatID =>
  key.slice(0, key.indexOf(":")) as ChatID

export const affects = (deps: QueryDeps, change: DbResidentChange): boolean => {
  if (deps.kinds.has(change.kind)) return true
  if (deps.refs.has(depRef(change.kind, String(change.id)))) return true
  return (
    change.kind === DbObjectKind.Message &&
    deps.messageChats.has(chatIdOfMessageKey(String(change.id)))
  )
}

class Collector {
  readonly deps = emptyDeps()
  private readonly rows = new Map<RowKey, Row>()

  constructor(private readonly view: ReplicaView) {}

  add(row: Row): RowKey {
    const key = rowKeyOf(row)
    this.rows.set(key, row)
    return key
  }

  chat(id: ChatID): Chat | undefined {
    this.deps.refs.add(depRef(DbObjectKind.Chat, id))
    return this.view.get(DbObjectKind.Chat, id)
  }

  addUser(id: UserID | undefined) {
    if (!id) return undefined
    this.deps.refs.add(depRef(DbObjectKind.User, id))
    const user = this.view.get(DbObjectKind.User, id)
    return user ? this.add(userRow(user)) : undefined
  }

  message(key: string): Message | undefined {
    this.deps.refs.add(depRef(DbObjectKind.Message, key))
    return this.view.get(DbObjectKind.Message, key)
  }

  /**
   * A chat's row, with the row ID of its last message when that message is
   * on the device. Every query builds chat rows here, so a chat row is the
   * same whichever subscription computed it. Returns the last message too.
   */
  chatWithLast(
    account: QueryAccount,
    chat: Chat,
  ): { key: RowKey; last: Message | undefined; lastKey: string | undefined } {
    const lastKey = chat.lastMsgId != null ? messageKey(chat.id, chat.lastMsgId) : undefined
    const last = lastKey ? this.message(lastKey) : undefined
    const row = chatRow(
      chat,
      last ? cachedMessageRow(last, account.clientKeyFor(last), account.userId, account).id : undefined,
    )
    return { key: this.add(row), last, lastKey }
  }

  /** A message row (through the account's identity) and its sender's row. */
  addMessage(account: QueryAccount, message: Message): RowKey {
    const key = this.add(cachedMessageRow(message, account.clientKeyFor(message), account.userId, account))
    this.addUser(message.fromId)
    return key
  }

  result(keys?: RowKey[], resource?: ResourceValue): QueryResult {
    return {
      rows: Array.from(this.rows.values()),
      ...(keys ? { keys } : {}),
      ...(resource ? { resource } : {}),
      deps: this.deps,
    }
  }
}

/**
 * Message rows by stored object. Committed objects are immutable snapshots,
 * so a row built once is reused until the object (or the client key that
 * names it) changes; the sidebar maps every chat's last message on each
 * recompute, and an equal row is then also identical, which makes its diff
 * free.
 */
const messageRows = new WeakMap<
  Message,
  {
    clientKey: string | undefined
    me: UserID
    row: MessageRow
    upload: MessageRow["upload"]
    tx: TxId | undefined
  }
>()

const cachedMessageRow = (
  message: Message,
  clientKey: string | undefined,
  me: UserID,
  account?: QueryAccount,
): MessageRow => {
  const upload = account?.localUpload?.(message)
  const tx = account?.sendTx?.(message)
  const cached = messageRows.get(message)
  if (cached && cached.clientKey === clientKey && cached.me === me && cached.upload === upload && cached.tx === tx) {
    return cached.row
  }
  let row = messageRow(message, clientKey, me)
  if (upload) {
    const media = localMedia(upload.attachment)
    row = { ...row, ...(media && !row.media ? { media } : {}), upload }
  }
  if (tx && row.state !== "sent") row = { ...row, tx }
  messageRows.set(message, { clientKey, me, row, upload, tx })
  return row
}

const emptyList = (): QueryResult => ({ rows: [], keys: [], deps: emptyDeps() })

export const computeQuery = (
  query: QueryDescriptor,
  env: QueryEnv,
  facts: SubscriptionFacts = {},
): QueryResult => {
  if (query.kind === "core") {
    return { rows: [], resource: env.core, deps: { ...emptyDeps(), core: true } }
  }
  const account = env.account
  if (!account || facts.invalid) {
    if (query.kind === "chatWindow") {
      return { ...emptyList(), resource: emptyWindow() }
    }
    if (query.kind === "chatParticipants" || query.kind === "spaceMembers") {
      return { ...emptyList(), resource: { kind: "roster", complete: false, loading: false } }
    }
    if (query.kind === "composeActions") {
      return { ...emptyList(), resource: { kind: "compose", activities: [] } }
    }
    if (query.kind === "media") {
      return { rows: [], deps: emptyDeps(), resource: { kind: "media", state: "absent" } }
    }
    if (query.kind === "chatMedia") {
      return { ...emptyList(), resource: { kind: "chatMedia", loading: false, hasMore: false, fetched: false } }
    }
    if (query.kind === "searchServerMessages" || query.kind === "searchUsers") {
      return {
        rows: [],
        deps: emptyDeps(),
        resource: { kind: "remoteSearch", status: "failed", reason: facts.invalid ? "invalid" : "unavailable" },
      }
    }
    if (handledQuery(query)) {
      return { rows: [], deps: emptyDeps(), resource: { kind: "search", status: "failed", reason: "unavailable" } }
    }
    return emptyList()
  }
  const view = account.view
  const collect = new Collector(view)

  switch (query.kind) {
    case "me": {
      const key = collect.addUser(account.userId)
      return collect.result(key ? [key] : [])
    }
    case "user": {
      const key = collect.addUser(query.userId)
      return collect.result(key ? [key] : [])
    }
    case "chat": {
      const chat = collect.chat(query.chatId)
      if (!chat) return collect.result([])
      const key = collect.chatWithLast(account, chat).key
      // The chat's dialog, when the account has one: not in the list.
      const dialogId = dialogIdForChat(chat)
      collect.deps.refs.add(depRef(DbObjectKind.Dialog, dialogId))
      const dialog = view.get(DbObjectKind.Dialog, dialogId)
      if (dialog) collect.add(dialogRow(dialog))
      return collect.result([key])
    }
    case "draft": {
      // The draft's key depends on the chat's peer.
      collect.chat(query.chatId)
      const { key, draft } = account.draftFor(query.chatId)
      collect.deps.refs.add(depRef(DbObjectKind.MessageDraft, key))
      return collect.result(draft ? [collect.add(draftRow(query.chatId, draft))] : [])
    }
    case "sidebar":
      return sidebar(collect, account, query.mode, query.spaceId)
    case "newMessages":
      return newMessages(collect, account, facts)
    case "chatWindow":
      return chatWindow(collect, account, query.chatId, facts)
    case "chatParticipants":
      return chatParticipants(collect, account, query.chatId)
    case "spaceMembers":
      return spaceMembers(collect, account, query.spaceId)
    case "userGroups": {
      collect.deps.kinds.add(DbObjectKind.UserGroup)
      const groups = view
        .all(DbObjectKind.UserGroup)
        .filter((group) => group.spaceId === query.spaceId)
        .sort(compareGroups)
      return collect.result(groups.map((group) => collect.add(userGroupRow(group))))
    }
    case "spaces": {
      collect.deps.kinds.add(DbObjectKind.Space)
      const spaces = view.all(DbObjectKind.Space).sort(compareSpaces)
      return collect.result(spaces.map((space) => collect.add(fullSpaceRow(space))))
    }
    case "userSettings": {
      collect.deps.kinds.add(DbObjectKind.UserSettings)
      const settings = view.get(DbObjectKind.UserSettings, "0")
      return collect.result(settings ? [collect.add(settingsRow(settings))] : [])
    }
    case "dialogFolders": {
      collect.deps.kinds.add(DbObjectKind.DialogFolder)
      const folders = view.all(DbObjectKind.DialogFolder).sort(compareFolders)
      return collect.result(folders.map((folder) => collect.add(folderRow(folder))))
    }
    case "composeActions": {
      const activities = (account.composeActivities?.(query.chatId) ?? []).slice()
      const keys: RowKey[] = []
      const seen = new Set<string>()
      for (const activity of activities) {
        if (seen.has(activity.userId)) continue
        seen.add(activity.userId)
        const key = collect.addUser(activity.userId)
        if (key) keys.push(key)
      }
      return collect.result(keys, { kind: "compose", activities })
    }
    case "media":
    case "searchMessages":
    case "findInChat":
    case "countMessages":
    case "searchServerMessages":
    case "searchUsers": {
      const resource = facts.handle != null ? account.handleResource?.(facts.handle) : undefined
      return collect.result(undefined, resource)
    }
    case "chatMedia":
      return chatMedia(collect, account, query.chatId, query.filter, facts)
  }
}

/** Queries whose state the host keeps per subscription (no rows). */
export const handledQuery = (query: QueryDescriptor): boolean =>
  query.kind === "media" ||
  query.kind === "searchMessages" ||
  query.kind === "findInChat" ||
  query.kind === "countMessages" ||
  query.kind === "searchServerMessages" ||
  query.kind === "searchUsers" ||
  query.kind === "chatMedia"

/** Newest first by server message ID. */
const byMessageIdDesc = (left: Message, right: Message) => {
  const a = BigInt(left.messageId)
  const b = BigInt(right.messageId)
  return a > b ? -1 : a < b ? 1 : 0
}

/**
 * A chat's shared media, files, voice or links, newest first: the device's
 * resident messages that match, and every message this subscription's disk
 * reads or server pages named (read from disk once when not resident).
 */
const chatMedia = (
  collect: Collector,
  account: QueryAccount,
  chatId: ChatID,
  filter: ChatMediaFilter,
  facts: SubscriptionFacts,
): QueryResult => {
  collect.deps.messageChats.add(chatId)
  const state = facts.handle != null ? account.chatMediaState?.(facts.handle) : undefined
  const found = new Map<string, Message>()
  for (const message of account.view.all(DbObjectKind.Message)) {
    if (message.chatId !== chatId || !isServerMessageId(message.messageId)) continue
    if (chatMediaMatches(message, filter)) found.set(message.id, message)
  }
  const missing: string[] = []
  for (const key of state?.listedKeys ?? []) {
    if (found.has(key)) continue
    const message = account.view.get(DbObjectKind.Message, key)
    // A listed message deleted since is gone from the replica: left out.
    if (message) {
      if (chatMediaMatches(message, filter)) found.set(key, message)
    } else {
      missing.push(key)
    }
  }
  if (missing.length > 0) account.wantMessages?.(missing)
  const keys: RowKey[] = []
  for (const message of Array.from(found.values()).sort(byMessageIdDesc)) {
    keys.push(collect.addMessage(account, message))
  }
  return collect.result(
    keys,
    state?.resource ?? { kind: "chatMedia", loading: false, hasMore: false, fetched: false },
  )
}

/**
 * A chat's direct participants: group grants first by name, then members
 * by display name and user ID, each with its user row.
 */
const chatParticipants = (collect: Collector, account: QueryAccount, chatId: ChatID): QueryResult => {
  const view = account.view
  collect.deps.kinds.add(DbObjectKind.ChatParticipant)
  collect.deps.kinds.add(DbObjectKind.ChatParticipantGroup)
  collect.deps.kinds.add(DbObjectKind.UserGroup)
  const chat = collect.chat(chatId)
  const keys: RowKey[] = []
  const groups = view
    .all(DbObjectKind.ChatParticipantGroup)
    .filter((grant) => grant.chatId === chatId)
    .flatMap((grant) => {
      const group = view.get(DbObjectKind.UserGroup, grant.groupId)
      return group ? [group] : []
    })
    .sort(compareGroups)
  for (const group of groups) keys.push(collect.add(userGroupRow(group)))
  const participants = view
    .all(DbObjectKind.ChatParticipant)
    .filter((participant) => participant.chatId === chatId)
    .map((participant) => {
      collect.deps.refs.add(depRef(DbObjectKind.User, participant.userId))
      const user = view.get(DbObjectKind.User, participant.userId)
      return { participant, userId: participant.userId, name: displayName(user) }
    })
    .sort(compareParticipants)
  for (const { participant } of participants) {
    keys.push(collect.add(participantRow(participant)))
    collect.addUser(participant.userId)
  }
  const fetch = account.roster?.("chat", chatId) ?? { loading: false, failed: false }
  return collect.result(keys, {
    kind: "roster",
    complete: chat?.participantRosterComplete === true,
    loading: fetch.loading,
    ...(fetch.failed ? { failed: true } : {}),
  })
}

/** A space's members: the account first, then by join date. */
const spaceMembers = (collect: Collector, account: QueryAccount, spaceId: string): QueryResult => {
  const view = account.view
  collect.deps.kinds.add(DbObjectKind.SpaceMember)
  collect.deps.refs.add(depRef(DbObjectKind.Space, spaceId))
  const space = view.get(DbObjectKind.Space, spaceId)
  const members = view
    .all(DbObjectKind.SpaceMember)
    .filter((member) => member.spaceId === spaceId)
    .sort(compareMembers(account.userId))
  const keys: RowKey[] = []
  for (const member of members) {
    keys.push(collect.add(spaceMemberRow(member)))
    collect.addUser(member.userId)
  }
  const fetch = account.roster?.("space", spaceId) ?? { loading: false, failed: false }
  return collect.result(keys, {
    kind: "roster",
    complete: space?.memberRosterComplete === true,
    loading: fetch.loading,
    ...(fetch.failed ? { failed: true } : {}),
  })
}

/**
 * The sidebar: ordered dialog rows, each with what its row view shows (the
 * Mac `ChatListItemSnapshot`): the chat, the peer user, the last message and
 * its sender, the draft, the space and, for a reply thread, the parent chat.
 *
 * It recomputes on any dialog, chat or draft change and on a change to a
 * listed last message, and diffs: a new last message in one chat sends that
 * chat's message, chat and dialog rows, and a list splice only when the
 * order changed.
 */
const sidebar = (
  collect: Collector,
  account: QueryAccount,
  mode: Extract<QueryDescriptor, { kind: "sidebar" }>["mode"],
  spaceId: Extract<QueryDescriptor, { kind: "sidebar" }>["spaceId"],
): QueryResult => {
  const view = account.view
  collect.deps.kinds.add(DbObjectKind.Dialog)
  collect.deps.kinds.add(DbObjectKind.Chat)
  const entries: SidebarEntry[] = view.all(DbObjectKind.Dialog).map((dialog) => {
    const chat = view.get(DbObjectKind.Chat, dialog.chatId)
    return { dialog, chat, activity: chat?.date ?? 0 }
  })
  const keys: RowKey[] = []
  const missing: string[] = []
  for (const { dialog, chat } of sortSidebar(entries, mode, spaceId)) {
    keys.push(collect.add(dialogRow(dialog)))
    collect.addUser(dialog.peerUserId ?? chat?.peerUserId)
    const draftKey = draftKeyFor(dialog, chat)
    collect.deps.refs.add(depRef(DbObjectKind.MessageDraft, draftKey))
    const draft = view.get(DbObjectKind.MessageDraft, draftKey)
    if (draft) collect.add(draftRow(dialog.chatId, draft))
    if (!chat) continue
    const { last, lastKey } = collect.chatWithLast(account, chat)
    if (last) collect.addMessage(account, last)
    else if (lastKey) missing.push(lastKey)
    const space = chat.spaceId ?? dialog.spaceId
    if (space) addSpace(collect, view, space)
    if (chat.parentChatId) {
      const parent = collect.chat(chat.parentChatId)
      if (parent) collect.chatWithLast(account, parent)
    }
  }
  if (missing.length > 0) account.wantMessages?.(missing)
  return collect.result(keys)
}

/** A chat's draft key without scanning dialogs (see `host/drafts.ts`). */
const draftKeyFor = (dialog: Dialog, chat: Chat | undefined) => {
  const peerUserId = chat?.peerUserId ?? dialog.peerUserId
  return messageDraftKey(
    peerUserId
      ? { peerKind: "user", peerUserId }
      : { peerKind: "chat", peerThreadId: dialog.chatId },
  )
}

const addSpace = (collect: Collector, view: ReplicaView, id: string) => {
  collect.deps.refs.add(depRef(DbObjectKind.Space, id))
  const space = view.get(DbObjectKind.Space, id)
  if (space) collect.add(spaceRow(space))
}

/**
 * The `newMessages` feed after the subscription's start (see
 * `host/new-messages.ts`), each message with its chat, dialog, sender,
 * space, parent chat, and the replied-to message and thread anchor when
 * they are on the device (so a UI can tell a reply to the user).
 */
const newMessages = (
  collect: Collector,
  account: QueryAccount,
  facts: SubscriptionFacts,
): QueryResult => {
  const view = account.view
  const keys: RowKey[] = []
  const feed = account.newMessages?.(facts.since ?? 0) ?? []
  if (feed.length > 0) collect.deps.kinds.add(DbObjectKind.Dialog)
  const dialogs =
    feed.length > 0
      ? new Map(view.all(DbObjectKind.Dialog).map((dialog) => [dialog.chatId, dialog]))
      : new Map<ChatID, Dialog>()
  for (const messageKeyValue of feed) {
    const message = collect.message(messageKeyValue)
    if (!message) continue
    keys.push(collect.addMessage(account, message))
    const chat = collect.chat(message.chatId)
    const dialog = dialogs.get(message.chatId)
    if (dialog) collect.add(dialogRow(dialog))
    if (message.replyToMsgId) {
      const replied = collect.message(messageKey(message.chatId, message.replyToMsgId))
      if (replied) collect.addMessage(account, replied)
    }
    if (!chat) continue
    collect.chatWithLast(account, chat)
    if (chat.spaceId) addSpace(collect, view, chat.spaceId)
    if (chat.parentChatId) {
      const parent = collect.chat(chat.parentChatId)
      if (parent) collect.chatWithLast(account, parent)
      if (chat.parentMessageId) {
        const anchor = collect.message(messageKey(chat.parentChatId, chat.parentMessageId))
        if (anchor) collect.addMessage(account, anchor)
      }
    }
  }
  return collect.result(keys)
}

const emptyWindow = (): WindowResource => ({
  kind: "window",
  hasOlder: false,
  hasNewer: false,
  atLatest: true,
  loading: "none",
})

/**
 * Window order: by date, and within one second the server's messages before
 * this device's sends (a send is newer than anything the server had when it
 * was made), sends in the order they were made. Temporary IDs are negative
 * and count down (`generateTempId`), so the newer send has the lower ID.
 * Without this, a send made in the same second as the latest message showed
 * above it until the server's ID moved it below.
 */
const compareWindowRows = (left: Message, right: Message): number => {
  const byDate = (left.date ?? 0) - (right.date ?? 0)
  if (byDate !== 0) return byDate
  const leftLocal = !isServerMessageId(left.messageId)
  const rightLocal = !isServerMessageId(right.messageId)
  if (leftLocal !== rightLocal) return leftLocal ? 1 : -1
  return leftLocal ? -compareMessagesByWindow(left, right) : compareMessagesByWindow(left, right)
}

const chatWindow = (
  collect: Collector,
  account: QueryAccount,
  chatId: ChatID,
  facts: SubscriptionFacts,
): QueryResult => {
  collect.deps.messageChats.add(chatId)
  // The edges compare the window with the chat's last message and its
  // certified history (invariant 5).
  const chat = collect.chat(chatId)
  collect.deps.refs.add(depRef(DbObjectKind.HistoryCoverage, chatId))
  const coverage = account.view.get(DbObjectKind.HistoryCoverage, chatId)
  const messages: Message[] = []
  for (const key of account.windowKeys(chatId)) {
    // A key whose message has not committed yet is left out until it has.
    const message = account.view.get(DbObjectKind.Message, key)
    if (message) messages.push(message)
  }
  messages.sort(compareWindowRows)
  const keys: RowKey[] = []
  for (const message of messages) {
    keys.push(collect.add(cachedMessageRow(message, account.clientKeyFor(message), account.userId, account)))
    collect.addUser(message.fromId)
  }
  const state = account.windowState(chatId)
  const serverIds = messages
    .filter((message) => isServerMessageId(message.messageId))
    .map((message) => BigInt(message.messageId))
  const edges = windowEdges({
    ranges: coverageRanges(coverage),
    ...(serverIds.length > 0
      ? {
          oldest: serverIds.reduce((a, b) => (a < b ? a : b)),
          newest: serverIds.reduce((a, b) => (a > b ? a : b)),
        }
      : {}),
    ...(chat?.lastMsgId != null ? { lastMsgId: BigInt(chat.lastMsgId) } : {}),
    ...(state.olderExhausted ? { olderExhausted: true } : {}),
  })
  const oldestId = serverIds.length > 0 ? serverIds.reduce((a, b) => (a < b ? a : b)) : undefined
  const newestId = serverIds.length > 0 ? serverIds.reduce((a, b) => (a > b ? a : b)) : undefined
  // The newest ID up to which the window's history is known contiguous: the
  // end of the certified run holding its oldest row, capped at its newest.
  const run = oldestId == null ? undefined : certifiedRangeAt(coverageRanges(coverage), oldestId)
  const certifiedThrough =
    run && newestId != null ? messageId(run[1] < newestId ? run[1] : newestId) : undefined
  const resource: WindowResource = {
    kind: "window",
    // TODO(contract): certifiedThrough. Not in `WindowResource` yet; the
    // rich-content agent is adding it to `core-protocol`.
    ...(certifiedThrough ? ({ certifiedThrough } as object) : {}),
    hasOlder: edges.hasOlder,
    hasNewer: edges.hasNewer,
    atLatest: edges.atLatest,
    loading: state.loading,
    ...(facts.unreadBoundary ? { unreadBoundary: facts.unreadBoundary } : {}),
  }
  return collect.result(keys, resource)
}
