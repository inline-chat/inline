/**
 * Builds the boot snapshot from a running session: what is on screen and
 * nothing else, within the byte budget. Pure apart from reading the
 * session; the saver decides when.
 */

import {
  receivedMessageRowId,
  rowKey,
  rowKeyOf,
  type QueryDescriptor,
  type Row,
  type RowKey,
  type WindowResource,
} from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import type { ClientSnapshotData } from "@inline/reactive"
import { relatedRowKeys, type AccountSession } from "@inline/view/features"
import {
  BOOT_SNAPSHOT_BUDGET,
  BOOT_SNAPSHOT_FORMAT,
  BOOT_SNAPSHOT_VERSION,
  SNAPSHOT_ROWS_ABOVE_PLACE,
  SNAPSHOT_SIDEBAR_ITEMS,
  SNAPSHOT_WINDOW_ROWS,
  type BootSnapshot,
} from "./format"

export type CaptureOptions = {
  readonly buildId: string
  /** Wall clock in milliseconds. */
  readonly now: () => number
  readonly budget?: number
  readonly sidebarItems?: number
  readonly windowRows?: number
  readonly rowsAbovePlace?: number
}

export type Capture = {
  readonly snapshot: BootSnapshot
  /** The serialized snapshot, as stored. */
  readonly text: string
  /** What the budget made it leave out, in the order it was dropped. */
  readonly dropped: readonly ("chat" | "sidebarRows")[]
}

/** The session's part the capture reads. `AccountSession` fits. */
export type CaptureSession = Pick<AccountSession, "userId" | "workspace" | "exportProvisional">

/** The chat pane keeps its reading place here (`features/chat`, `ChatViewState`). */
type ChatViewState = { readonly place?: { readonly messageId?: unknown } }

const focusedChat = (session: CaptureSession): ChatID | undefined => {
  const destination = session.workspace.focusedDestination.peek()
  // A message destination (a link) opens around that message, not the saved place.
  if (destination.kind === "chat") return destination.chatId
  if (destination.kind === "thread") return destination.threadId
  return undefined
}

const savedPlace = (session: CaptureSession, chatId: ChatID): MessageID | undefined => {
  const state = session.workspace.viewState.get<ChatViewState>({ kind: "chat", chatId })
  const id = state?.place?.messageId
  return typeof id === "string" ? (id as MessageID) : undefined
}

/** Drop rows that no list reaches any more. */
const prune = (data: ClientSnapshotData): ClientSnapshotData => {
  const byKey = new Map<RowKey, Row>(data.store.rows.map((row) => [rowKeyOf(row), row]))
  const keep = new Set<RowKey>()
  const pending: RowKey[] = []
  const visit = (key: RowKey) => {
    if (keep.has(key) || !byKey.has(key)) return
    keep.add(key)
    pending.push(key)
  }
  for (const list of data.store.lists) for (const key of list.keys) visit(key)
  for (let key = pending.pop(); key !== undefined; key = pending.pop()) {
    const row = byKey.get(key)
    if (row) for (const related of relatedRowKeys(row)) visit(related)
  }
  return { ...data, store: { ...data.store, rows: data.store.rows.filter((row) => keep.has(rowKeyOf(row))) } }
}

const withoutQuery = (data: ClientSnapshotData, kind: QueryDescriptor["kind"]): ClientSnapshotData => {
  const subs = new Set(data.queries.filter((entry) => entry.query.kind === kind).map((entry) => entry.sub))
  return prune({
    ...data,
    queries: data.queries.filter((entry) => !subs.has(entry.sub)),
    store: { ...data.store, lists: data.store.lists.filter((list) => !subs.has(list.sub)) },
  })
}

const sidebarLength = (data: ClientSnapshotData): number => {
  const sub = data.queries.find((entry) => entry.query.kind === "sidebar")?.sub
  return data.store.lists.find((list) => list.sub === sub)?.keys.length ?? 0
}

const withSidebarItems = (data: ClientSnapshotData, count: number): ClientSnapshotData => {
  const sub = data.queries.find((entry) => entry.query.kind === "sidebar")?.sub
  return prune({
    ...data,
    store: {
      ...data.store,
      lists: data.store.lists.map((list) => (list.sub === sub ? { ...list, keys: list.keys.slice(0, count) } : list)),
    },
  })
}

/**
 * Capture what to paint the next start from. Undefined when nothing fits
 * the budget (or the session is gone); the caller then erases what is stored.
 */
export const captureBootSnapshot = (session: CaptureSession, options: CaptureOptions): Capture | undefined => {
  const budget = options.budget ?? BOOT_SNAPSHOT_BUDGET
  const sidebarItems = options.sidebarItems ?? SNAPSHOT_SIDEBAR_ITEMS
  const windowRows = options.windowRows ?? SNAPSHOT_WINDOW_ROWS
  const above = Math.min(options.rowsAbovePlace ?? SNAPSHOT_ROWS_ABOVE_PLACE, windowRows - 1)

  const chatId = focusedChat(session)
  const place = chatId !== undefined ? savedPlace(session, chatId) : undefined
  let cut: { above: boolean; below: boolean; around?: MessageID } | undefined
  const exported = session.exportProvisional({
    ...(chatId !== undefined ? { chatId } : {}),
    select: (query, keys) => {
      if (query.kind === "sidebar") return keys.slice(0, sidebarItems)
      if (query.kind !== "chatWindow") return keys
      // Rows around the reading place (its message is the first on screen),
      // or the newest rows when the reader was at the end.
      const at = place !== undefined ? keys.indexOf(rowKey("message", receivedMessageRowId(query.chatId, place))) : -1
      const start = at >= 0 ? Math.max(0, at - above) : Math.max(0, keys.length - windowRows)
      const end = Math.min(keys.length, start + windowRows)
      cut = { above: start > 0, below: end < keys.length, ...(at >= 0 && place !== undefined ? { around: place } : {}) }
      return keys.slice(start, end)
    },
  })
  if (!exported) return undefined

  let data: ClientSnapshotData = exported
  let chat: BootSnapshot["chat"]
  const windowSub = data.queries.find((entry) => entry.query.kind === "chatWindow")?.sub
  const windowList = data.store.lists.find((list) => list.sub === windowSub)
  const resource = windowList?.resource
  if (chatId !== undefined && windowList && windowList.keys.length > 0 && resource?.kind === "window" && cut) {
    const trimmed = cut
    // What the cut window can honestly say. The unread boundary is left out:
    // it was fixed for the visit that ended; the core's window brings the new one.
    const { unreadBoundary: _visit, ...rest } = resource
    const window: WindowResource = {
      ...rest,
      loading: "none",
      hasOlder: resource.hasOlder || trimmed.above,
      hasNewer: resource.hasNewer || trimmed.below,
      atLatest: resource.atLatest && !trimmed.below,
    }
    data = {
      ...data,
      store: {
        ...data.store,
        lists: data.store.lists.map((list) => (list.sub === windowSub ? { ...list, resource: window } : list)),
      },
    }
    chat = { chatId, ...(trimmed.around ? { around: trimmed.around } : {}) }
  } else if (windowSub !== undefined) {
    // Nothing to paint the chat from (not loaded yet).
    data = withoutQuery(data, "chatWindow")
  }

  const make = (client: ClientSnapshotData, withChat: boolean): BootSnapshot => ({
    format: BOOT_SNAPSHOT_FORMAT,
    version: BOOT_SNAPSHOT_VERSION,
    build: options.buildId,
    user: session.userId,
    savedAt: options.now(),
    ...(withChat && chat ? { chat } : {}),
    client,
  })

  const dropped: ("chat" | "sidebarRows")[] = []
  let withChat = chat !== undefined
  let snapshot = make(data, withChat)
  let text = JSON.stringify(snapshot)
  if (text.length > budget && withChat) {
    // The chat window goes first: the sidebar is what every start shows.
    data = withoutQuery(data, "chatWindow")
    withChat = false
    dropped.push("chat")
    snapshot = make(data, withChat)
    text = JSON.stringify(snapshot)
  }
  for (let count = sidebarLength(data); text.length > budget && count > 0; ) {
    count = Math.floor(count / 2)
    data = withSidebarItems(data, count)
    if (!dropped.includes("sidebarRows")) dropped.push("sidebarRows")
    snapshot = make(data, withChat)
    text = JSON.stringify(snapshot)
  }
  if (text.length > budget) return undefined
  return { snapshot, text, dropped }
}
