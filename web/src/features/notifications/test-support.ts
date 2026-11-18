/**
 * A real `AccountSession` over a scripted core and a fake platform, for the
 * notification tests. The core side is driven by hand: open a chat's window,
 * deliver its first page, deliver a new message through the `newMessages`
 * feed (and the chat's window when one is open), page older.
 */

import {
  rowKeyOf,
  type ChatRow,
  type DialogRow,
  type MessageRow,
  type QueryDescriptor,
  type Row,
  type RowKey,
  type SubId,
  type UserRow,
  type WindowResource,
} from "@inline/core-protocol"
import type { ChatID, DialogID, MessageID, UserID } from "@inline/ids"
import { createFakePlatform, manualClock, type FakePlatform } from "@inline/platform/testing"
import { createScheduler, createStoreClient, manualTime, signal, type ManualTime } from "@inline/reactive"
import { message as baseMessage, scriptedEndpoint, type ScriptedEndpoint } from "@inline/reactive/testing"
import { AccountSession } from "@inline/view/features"
import { attachNotifications, type AttachNotificationsOptions, type NotificationsAttachment } from "./attach"
import type { CoreRole } from "./notification-controller"

export const cid = (n: number) => String(n) as ChatID
export const uid = (n: number) => String(n) as UserID
export const mid = (n: number) => String(n) as MessageID
export const did = (n: number) => String(n) as DialogID

/** The signed-in user. Messages from `message()` come from user 1 by default. */
export const ME = uid(9)

/** Message dates are `1_700_000_000 + id` seconds; "now" is 100 s later, so low IDs are fresh. */
export const NOW_MS = 1_700_000_100_000

export const message = (chat: number, id: number, text = `message ${id}`, extra: Partial<MessageRow> = {}) =>
  baseMessage(chat, id, text, extra)

export const userRow = (n: number, firstName: string, extra: Partial<UserRow> = {}): UserRow => ({
  kind: "user",
  id: uid(n),
  firstName,
  ...extra,
})

/** A chat row as the core publishes it: with its dialog's ID (`ChatRow.dialogId`; dialog `n` here). */
export const chatRow = (n: number, extra: Partial<ChatRow> = {}): ChatRow => ({ kind: "chat", id: cid(n), dialogId: did(n), ...extra })

export const dialogRow = (n: number, extra: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: did(n),
  chatId: cid(n),
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...extra,
})

export const windowResource = (extra: Partial<WindowResource> = {}): WindowResource => ({
  kind: "window",
  hasOlder: false,
  hasNewer: false,
  atLatest: true,
  loading: "none",
  ...extra,
})

const upserts = (rows: readonly Row[]) => rows.map((row) => ({ op: "upsert" as const, row }))

const microtasks = async (rounds = 8) => {
  for (let i = 0; i < rounds; i++) await Promise.resolve()
}

export type Context = {
  readonly time: ManualTime
  readonly endpoint: ScriptedEndpoint
  readonly fake: FakePlatform
  readonly session: AccountSession
  readonly role: ReturnType<typeof signal<CoreRole | undefined>>
  attachment: NotificationsAttachment | undefined
  attach(extra?: Partial<AttachNotificationsOptions>): NotificationsAttachment
  /** Apply what the core delivered (the frame lane), then let promises settle. */
  flush(): Promise<void>
  sub(match: (query: QueryDescriptor) => boolean): SubId
  /** The window subscription of a chat. */
  windowSub(chat: number): SubId
  /** Deliver rows and patch lists, keeping the keys of each list. */
  deliver(parts: {
    rows?: readonly Row[]
    lists?: readonly { sub: SubId; keys: readonly RowKey[] }[]
    windows?: readonly { sub: SubId; value: WindowResource }[]
  }): Promise<void>
  keys(sub: SubId): RowKey[]
  /** Put dialogs and chats in the sidebar lists (inbox and all). */
  sidebar(rows: readonly (DialogRow | ChatRow | UserRow)[]): Promise<void>
  /** Make a chat resident (a pane holding it) and deliver its first page. */
  openChat(chat: number, messages: readonly MessageRow[], window?: Partial<WindowResource>): Promise<{ sub: SubId; release(): void }>
  /** The `newMessages` subscription. */
  feedSub(): SubId
  /**
   * A new message: the core lists it in the `newMessages` feed with its extra
   * rows (chat, dialog, sender), and appends it to the chat's window when one
   * is subscribed.
   */
  arrive(chat: number, row: MessageRow, extraRows?: readonly Row[]): Promise<void>
}

export const setup = (options: { role?: CoreRole | undefined; residentChats?: number } = {}): Context => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler })
  const fake = createFakePlatform({ clock: manualClock(NOW_MS) })
  const session = new AccountSession({
    userId: ME,
    token: "t",
    clock: time,
    residentChats: options.residentChats ?? 3,
    connect: () => ({
      core: endpoint,
      client,
      close: () => {
        client.dispose()
        endpoint.close()
      },
    }),
  })
  const role = signal<CoreRole | undefined>("role" in options ? options.role : "leader")
  const lists = new Map<SubId, RowKey[]>()

  const live = () => {
    const subs = new Map<SubId, QueryDescriptor>()
    for (const command of endpoint.posted) {
      if (command.kind === "subscribe") subs.set(command.sub, command.query)
      if (command.kind === "unsubscribe") subs.delete(command.sub)
    }
    return subs
  }
  const flush = async () => {
    time.frame()
    await microtasks()
  }
  const sub = (match: (query: QueryDescriptor) => boolean): SubId => {
    let found: SubId | undefined
    for (const [id, query] of live()) if (match(query)) found = id
    if (found === undefined) throw new Error("no matching subscription")
    return found
  }
  const windowSub = (chat: number) => sub((q) => q.kind === "chatWindow" && q.chatId === cid(chat))

  const context: Context = {
    time,
    endpoint,
    fake,
    session,
    role,
    attachment: undefined,
    attach(extra = {}) {
      context.attachment = attachNotifications({
        session,
        platform: fake.platform,
        role,
        clock: fake.clock,
        ...extra,
      })
      return context.attachment
    },
    flush,
    sub,
    windowSub,
    keys: (s) => [...(lists.get(s) ?? [])],
    async deliver(parts) {
      for (const list of parts.lists ?? []) lists.set(list.sub, [...list.keys])
      endpoint.patch({
        rows: upserts(parts.rows ?? []),
        lists: (parts.lists ?? []).map((list) => ({ sub: list.sub, op: "replace" as const, keys: [...list.keys] })),
        resources: (parts.windows ?? []).map((w) => ({ sub: w.sub, value: w.value })),
      })
      await flush()
    },
    async sidebar(rows) {
      const inbox = sub((q) => q.kind === "sidebar" && q.mode === "inbox")
      const all = sub((q) => q.kind === "sidebar" && q.mode === "all")
      const dialogKeys = rows.filter((row) => row.kind === "dialog").map(rowKeyOf)
      await context.deliver({ rows, lists: [{ sub: inbox, keys: dialogKeys }, { sub: all, keys: dialogKeys }] })
    },
    async openChat(chat, messages, window = {}) {
      const lease = session.openChat(cid(chat))
      const s = windowSub(chat)
      await context.deliver({
        rows: messages,
        lists: [{ sub: s, keys: messages.map(rowKeyOf) }],
        windows: [{ sub: s, value: windowResource(window) }],
      })
      return { sub: s, release: lease.release }
    },
    feedSub: () => sub((q) => q.kind === "newMessages"),
    async arrive(chat, row, extraRows = []) {
      const feed = context.feedSub()
      const lists = [{ sub: feed, keys: [...context.keys(feed), rowKeyOf(row)] }]
      const window = [...live()].find(([, q]) => q.kind === "chatWindow" && q.chatId === cid(chat))
      if (window) lists.push({ sub: window[0], keys: [...context.keys(window[0]), rowKeyOf(row)] })
      await context.deliver({ rows: [...extraRows, row], lists })
    },
  }
  return context
}
