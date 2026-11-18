/**
 * A stand-in for the core, for the sidebar lab: it answers `sidebar`
 * subscriptions over the scripted endpoint from `@inline/reactive/testing`
 * and turns lab operations into patches. It orders the list the way the core
 * does (rule 6: pinned first, then recent activity) and filters it by mode
 * (inbox: open or pinned; all: not archived).
 */

import type { Command, CoreEndpoint, DialogRow, QueryDescriptor, Row, RowKey, SubId } from "@inline/core-protocol"
import { rowKey } from "@inline/core-protocol"
import { computed, signal, type ReadSignal } from "@inline/reactive"
import { scriptedEndpoint, type ScriptedEndpoint } from "@inline/reactive/testing"
import { chatIdOf, generateAccount, LONG_TITLE, ME, messageRow, nextMessages, type LabChat } from "./lab-data"

type SidebarQuery = Extract<QueryDescriptor, { kind: "sidebar" }>

/** Milliseconds before the core answers a subscription, or "never" to stay in the first-load state. */
export type Latency = 0 | 400 | 2000 | "never"

const dialogKey = (chat: LabChat): RowKey => rowKey("dialog", chat.dialog.id)

export class LabCore {
  readonly endpoint: CoreEndpoint
  readonly scripted: ScriptedEndpoint
  readonly latency = signal<Latency>(0)
  /** True once the newest `sidebar` subscription has its first answer. */
  readonly ready: ReadSignal<boolean>
  readonly count: ReadSignal<number>

  readonly #subs = new Map<SubId, SidebarQuery>()
  readonly #answered = signal<ReadonlySet<SubId>>(new Set())
  readonly #latest = signal<SubId | undefined>(undefined)
  /** Subscriptions whose first answer was sent (the flag above may lag a frame). */
  readonly #answering = new Set<SubId>()
  readonly #count = signal(0)
  #chats = new Map<number, LabChat>()
  #users: Row[] = []
  /** Chat numbers, most recent activity first (pinned ones included; sorted at publish). */
  #recency: number[] = []
  #pinOrder: number[] = []
  #nextMessage = 10_000_000
  #clock = 0
  #timers = new Set<ReturnType<typeof setTimeout>>()

  /**
   * `defer` runs the "answered" flag in the same frame-lane batch as the
   * patch it follows, so `ready` never turns true a frame before the list.
   */
  constructor(
    count: number,
    private readonly defer: (fn: () => void) => void = (fn) => fn(),
  ) {
    this.scripted = scriptedEndpoint()
    const scripted = this.scripted
    this.endpoint = {
      post: (command) => {
        scripted.post(command)
        this.#onCommand(command)
      },
      subscribe: (listener) => scripted.subscribe(listener),
      close: () => {
        for (const timer of this.#timers) clearTimeout(timer)
        scripted.close()
      },
    }
    this.ready = computed(() => {
      const latest = this.#latest.get()
      return latest !== undefined && this.#answered.get().has(latest)
    })
    this.count = this.#count
    this.#load(count)
  }

  // MARK: Queries

  chat(n: number): LabChat | undefined {
    return this.#chats.get(n)
  }

  chatByDialogKey(key: RowKey): LabChat | undefined {
    const id = Number(key.slice("dialog:".length))
    return this.#chats.get(id)
  }

  // MARK: Operations (each publishes one patch)

  /** Replace the whole account with `count` generated chats. */
  scale(count: number): void {
    this.#load(count)
    this.#publish([...this.#users, ...this.#allRows()])
  }

  /** A new message: the chat moves to the top (after pins); incoming ones add unread. */
  newMessage(n: number, out = false): void {
    const chat = this.#chats.get(n)
    if (!chat) return
    const id = this.#nextMessage++
    const date = this.#now()
    const from = out ? ME : (chat.dialog.peerUserId ?? ME)
    const text = nextMessages[id % nextMessages.length]!
    chat.last = messageRow(n, id, text, out, date, from)
    chat.chat = { ...chat.chat, lastMessageId: chat.last.messageId!, lastActivityDate: date }
    chat.dialog = {
      ...chat.dialog,
      open: true,
      ...(out ? { unreadCount: 0, unreadMark: false } : { unreadCount: chat.dialog.unreadCount + 1 }),
    }
    this.#recency = [n, ...this.#recency.filter((other) => other !== n)]
    this.#publish([chat.last, chat.chat, chat.dialog])
  }

  setUnread(n: number, unreadCount: number, unreadMark = false): void {
    this.#updateDialog(n, { unreadCount, unreadMark })
  }

  setDraft(n: number, text: string): void {
    const chat = this.#chats.get(n)
    if (!chat) return
    chat.draft = { kind: "draft", id: chatIdOf(n), text, revision: (chat.draft?.revision ?? 0) + 1 }
    this.#publish([chat.draft])
  }

  togglePin(n: number): void {
    const chat = this.#chats.get(n)
    if (!chat) return
    const pinned = !chat.dialog.pinned
    this.#pinOrder = pinned ? [...this.#pinOrder, n] : this.#pinOrder.filter((other) => other !== n)
    this.#updateDialog(n, { pinned, open: true })
  }

  setOpen(n: number, open: boolean): void {
    this.#updateDialog(n, { open })
  }

  toggleArchive(n: number): void {
    const chat = this.#chats.get(n)
    if (chat) this.#updateDialog(n, { archived: !chat.dialog.archived })
  }

  /** `setDialogNotifications`: "default" clears the chat's own mode. */
  setNotifications(n: number, mode: "default" | "all" | "mentions" | "none"): void {
    const chat = this.#chats.get(n)
    if (!chat) return
    const { notificationMode: _old, ...rest } = chat.dialog
    chat.dialog = mode === "default" ? rest : { ...rest, notificationMode: mode }
    this.#updateDialog(n, {})
  }

  /** `setDialogFollow`: "relevance" clears the thread's own mode. */
  setFollow(n: number, mode: "relevance" | "following" | "unfollowed"): void {
    const chat = this.#chats.get(n)
    if (!chat) return
    const { followMode: _old, ...rest } = chat.dialog
    chat.dialog = mode === "relevance" ? rest : { ...rest, followMode: mode }
    this.#updateDialog(n, {})
  }

  rename(n: number): void {
    const chat = this.#chats.get(n)
    if (!chat || chat.chat.peerUserId) return
    chat.chat = { ...chat.chat, title: chat.chat.title === LONG_TITLE ? "Renamed thread" : LONG_TITLE }
    this.#publish([chat.chat])
  }

  /**
   * Reverse the order of `span` non-pinned chats starting at `from` (list
   * positions), without changing any row: a pure reorder. The core would
   * only do this for a manual order; here it shows that a reorder renders
   * no row.
   */
  reorder(from: number, span: number): void {
    // Rows the inbox shows, so the reversed block is on screen in either mode.
    const unpinned = this.#recency.filter((n) => {
      const dialog = this.#chats.get(n)?.dialog
      return dialog !== undefined && !dialog.pinned && dialog.open && !dialog.archived
    })
    const block = unpinned.slice(from, from + span)
    if (block.length < 2) return
    const reversed = [...block].reverse()
    const replace = new Map(block.map((n, index) => [n, reversed[index]!]))
    this.#recency = this.#recency.map((n) => replace.get(n) ?? n)
    this.#publish([])
  }

  /** Forget answers and subscriptions' readiness, as a restart does. */
  dispose(): void {
    this.endpoint.close()
  }

  // MARK: Internals

  #load(count: number) {
    const account = generateAccount(count)
    this.#users = account.users
    this.#chats = new Map(account.chats.map((chat) => [chat.n, chat]))
    this.#recency = account.chats.map((chat) => chat.n)
    this.#pinOrder = account.chats.filter((chat) => chat.dialog.pinned).map((chat) => chat.n)
    this.#clock = 1_790_000_000 + 60
    this.#count.set(count)
  }

  #now(): number {
    this.#clock += 1
    return this.#clock
  }

  #allRows(): Row[] {
    const rows: Row[] = []
    for (const chat of this.#chats.values()) {
      rows.push(chat.dialog, chat.chat)
      if (chat.last) rows.push(chat.last)
      if (chat.draft) rows.push(chat.draft)
    }
    return rows
  }

  #updateDialog(n: number, patch: Partial<DialogRow>) {
    const chat = this.#chats.get(n)
    if (!chat) return
    chat.dialog = { ...chat.dialog, ...patch }
    this.#publish([chat.dialog])
  }

  /** Rule 6 (simplified): pinned by pin order, then most recent activity. Then the mode's filter. */
  #keys(query: SidebarQuery): RowKey[] {
    const pinned = this.#pinOrder.map((n) => this.#chats.get(n)).filter((chat): chat is LabChat => chat !== undefined)
    const rest = this.#recency
      .map((n) => this.#chats.get(n))
      .filter((chat): chat is LabChat => chat !== undefined && !chat.dialog.pinned)
    const visible = (chat: LabChat) =>
      !chat.dialog.archived && (query.mode === "all" || chat.dialog.open || chat.dialog.pinned)
    return [...pinned, ...rest].filter(visible).map(dialogKey)
  }

  #publish(rows: Row[], only?: SubId) {
    const lists = [...this.#subs]
      .filter(([sub]) => this.#answering.has(sub) || sub === only)
      .map(([sub, query]) => ({ sub, op: "replace" as const, keys: this.#keys(query) }))
    if (rows.length === 0 && lists.length === 0) return
    this.scripted.patch({ rows: rows.map((row) => ({ op: "upsert" as const, row })), lists })
  }

  #onCommand(command: Command) {
    if (command.kind === "unsubscribe") {
      this.#subs.delete(command.sub)
      this.#answering.delete(command.sub)
      return
    }
    if (command.kind !== "subscribe" || command.query.kind !== "sidebar") return
    const sub = command.sub
    const firstAnswer = this.#answering.size === 0
    this.#subs.set(sub, command.query)
    this.#latest.set(sub)
    const answer = () => {
      if (!this.#subs.has(sub)) return
      // The first answer carries the rows; later ones only the list.
      this.#publish(firstAnswer ? [...this.#users, ...this.#allRows()] : [], sub)
      this.#answering.add(sub)
      this.defer(() => {
        const answered = new Set(this.#answered.peek())
        answered.add(sub)
        this.#answered.set(answered)
      })
    }
    const latency = this.latency.peek()
    if (latency === "never") return
    // Always on a later task, as a worker's message would be.
    const timer = setTimeout(() => {
      this.#timers.delete(timer)
      answer()
    }, latency)
    this.#timers.add(timer)
  }
}
