/**
 * The message lab's model: row signals (so changing one message re-renders
 * one row, as the view store does), timeline items from the real
 * `timelineItems`, the row actions, a highlight, and a streaming driver.
 * Framework-free; the views read it through `useSignal`.
 */

import { createTimeFormatter, type TimeFormatter } from "@inline/chat-ui"
import type { MessageRow, MessageRowId, ReactionSummary } from "@inline/core-protocol"
import type { MessageID } from "@inline/ids"
import { computed, type ReadSignal, type Signal, signal } from "@inline/reactive"
import { type TimelineItem, timelineItems } from "@inline/timeline"
import { Lazy, loadMenuKit, type MenuKitCore } from "@inline/ui"
import { createEmojiEngineLoader, type EmojiEngineLoader } from "../../features/emoji"
import {
  createMessageTimes,
  FindHighlights,
  findOccurrences,
  type FindRanges,
  type MessageAction,
  MessageActionsController,
  type MessageTimes,
  presentReply,
  presentSender,
  type ReplyPresentation,
  type SenderPresentation,
} from "../../features/message"
import {
  contentRows,
  directionRows,
  GALLERY_UNREAD_BOUNDARY,
  galleryRows,
  longListRows,
  STREAM_ROW_ID,
  STREAM_TEXT,
  streamRow,
  userById,
  VIEWER_ID,
} from "./fixtures"

const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone

export class MessageLab {
  readonly formatter: TimeFormatter = createTimeFormatter()
  readonly times: MessageTimes = createMessageTimes(this.formatter)
  readonly actions: MessageActionsController
  readonly galleryItems: readonly TimelineItem[]
  readonly longItems: readonly TimelineItem[]
  readonly directionItems: readonly TimelineItem[]
  readonly contentItems: readonly TimelineItem[]

  readonly isDM = signal(false)
  readonly loadingOlder = signal(true)
  readonly streaming = signal(false)
  readonly log = signal("Hover a message, focus one with Tab, or right-click it.")
  readonly find = new FindHighlights()
  /** Emoji names for the chips' accessible names: `loadEmojiNames()` loads the real data. */
  readonly emoji: EmojiEngineLoader = createEmojiEngineLoader()
  /** How long the menu's code takes to arrive the first time (a slow network), in ms. */
  menuDelay = 0
  readonly #menuKit = new Lazy<MenuKitCore>(
    () => new Promise((resolve, reject) => setTimeout(() => void loadMenuKit().then(resolve, reject), this.menuDelay)),
  )
  readonly findStatus = signal("")
  #matches: { rowId: MessageRowId; ranges: FindRanges }[] = []
  #matchIndex = 0
  #searchOrder: MessageRowId[] = []

  readonly #rows = new Map<MessageRowId, Signal<MessageRow>>()
  readonly #byMessageId = new Map<MessageID, MessageRowId>()
  readonly #highlight = signal<{ rowId: MessageRowId; seq: number } | null>(null)
  readonly #highlightFor = new Map<MessageRowId, ReadSignal<number | undefined>>()
  #seq = 0
  #streamTimer: ReturnType<typeof setInterval> | undefined
  #streamLength = 0

  constructor() {
    const gallery = galleryRows()
    const long = longListRows(500)
    const direction = directionRows()
    const content = contentRows()
    for (const row of [...gallery, ...long, ...direction, ...content, streamRow(0)]) {
      this.#rows.set(row.id, signal(row))
      if (row.messageId) this.#byMessageId.set(row.messageId, row.id)
    }
    this.galleryItems = timelineItems({
      rows: gallery,
      viewerId: VIEWER_ID,
      timeZone,
      unread: { boundary: GALLERY_UNREAD_BOUNDARY, reachesHistoryStart: true },
    }).items
    this.longItems = timelineItems({ rows: long, viewerId: VIEWER_ID, timeZone }).items
    this.directionItems = timelineItems({ rows: direction, viewerId: VIEWER_ID, timeZone }).items
    this.contentItems = timelineItems({ rows: content, viewerId: VIEWER_ID, timeZone }).items
    this.actions = new MessageActionsController({ actionsFor: (rowId) => this.#actionsFor(rowId), menuKit: this.#menuKit })
    this.#searchOrder = [...gallery, ...content, ...direction].map((row) => row.id)
  }

  // Find in chat (a stand-in for the find controller): every row with a
  // match is a result; the active one is highlighted.

  search(query: string): MessageRowId | undefined {
    this.#matches = []
    for (const rowId of this.#searchOrder) {
      const row = this.#rows.get(rowId)?.peek()
      const ranges = row ? findOccurrences(row.text, query) : undefined
      if (ranges) this.#matches.push({ rowId, ranges })
    }
    this.#matchIndex = 0
    return this.#showMatch()
  }

  nextMatch(step: 1 | -1): MessageRowId | undefined {
    if (this.#matches.length === 0) return undefined
    this.#matchIndex = (this.#matchIndex + step + this.#matches.length) % this.#matches.length
    return this.#showMatch()
  }

  #showMatch(): MessageRowId | undefined {
    const match = this.#matches[this.#matchIndex]
    if (!match) {
      this.find.clear()
      this.findStatus.set(this.#matches.length === 0 ? "No results" : "")
      return undefined
    }
    this.find.showRow(match.rowId, match.ranges)
    this.findStatus.set(`${this.#matchIndex + 1} of ${this.#matches.length}`)
    return match.rowId
  }

  row(rowId: MessageRowId): ReadSignal<MessageRow | undefined> {
    return this.#rows.get(rowId) ?? missing
  }

  update(rowId: MessageRowId, change: (row: MessageRow) => MessageRow): void {
    const row = this.#rows.get(rowId)
    if (row) row.set(change(row.peek()))
  }

  sender(row: MessageRow): SenderPresentation | undefined {
    const user = userById.get(row.fromId)
    return user ? presentSender(user) : undefined
  }

  reply(row: MessageRow): ReplyPresentation | undefined {
    const target = row.replyToMessageId
    if (target === undefined) return undefined
    const rowId = this.#byMessageId.get(target)
    const replied = rowId ? this.#rows.get(rowId)?.peek() : undefined
    return presentReply(target, replied, replied ? this.sender(replied) : undefined)
  }

  /** The highlight number for one row, as a per-row signal (one row re-renders per flash). */
  highlightFor(rowId: MessageRowId): ReadSignal<number | undefined> {
    let cached = this.#highlightFor.get(rowId)
    if (!cached) {
      cached = computed(() => {
        const current = this.#highlight.get()
        return current?.rowId === rowId ? current.seq : undefined
      })
      this.#highlightFor.set(rowId, cached)
    }
    return cached
  }

  flash(rowId: MessageRowId): void {
    this.#seq += 1
    this.#highlight.set({ rowId, seq: this.#seq })
  }

  note(text: string): void {
    this.log.set(text)
  }

  toggleReaction(rowId: MessageRowId, emoji: string): void {
    this.update(rowId, (row) => {
      const list = row.reactions ?? []
      const existing = list.find((reaction) => reaction.emoji === emoji)
      let next: ReactionSummary[]
      if (!existing) next = [...list, { emoji, count: 1, mine: true }]
      else if (existing.mine)
        next = list
          .map((reaction) => (reaction.emoji === emoji ? { ...reaction, count: reaction.count - 1, mine: false } : reaction))
          .filter((reaction) => reaction.count > 0)
      else next = list.map((reaction) => (reaction.emoji === emoji ? { ...reaction, count: reaction.count + 1, mine: true } : reaction))
      return { ...row, reactions: next }
    })
  }

  /** sending, then sent after a moment: what a resend looks like. */
  resend(rowId: MessageRowId): void {
    this.update(rowId, (row) => ({ ...row, state: "sending" }))
    setTimeout(() => this.update(rowId, (row) => ({ ...row, state: "sent" })), 900)
  }

  /** Steps a row through sending, sent, failed and uncertain. */
  cycleState(rowId: MessageRowId): void {
    const order = ["sending", "sent", "failed", "uncertain"] as const
    this.update(rowId, (row) => ({ ...row, state: order[(order.indexOf(row.state) + 1) % order.length] ?? "sent" }))
  }

  // Streaming

  /** Grows the streaming row by a few characters `rate` times a second. */
  startStream(rate = 30): void {
    if (this.#streamTimer !== undefined) return
    if (this.#streamLength >= STREAM_TEXT.length) this.#streamLength = 0
    this.streaming.set(true)
    this.#streamTimer = setInterval(() => {
      this.#streamLength = Math.min(STREAM_TEXT.length, this.#streamLength + 2 + Math.floor(Math.random() * 5))
      const next = streamRow(this.#streamLength)
      this.update(STREAM_ROW_ID, (row) => ({ ...next, date: row.date }))
      if (this.#streamLength >= STREAM_TEXT.length) this.stopStream()
    }, 1000 / rate)
  }

  stopStream(): void {
    if (this.#streamTimer !== undefined) clearInterval(this.#streamTimer)
    this.#streamTimer = undefined
    this.streaming.set(false)
  }

  resetStream(): void {
    this.stopStream()
    this.#streamLength = 0
    this.update(STREAM_ROW_ID, () => streamRow(0))
  }

  // Actions

  #actionsFor(rowId: MessageRowId): readonly MessageAction[] {
    const row = this.#rows.get(rowId)?.get()
    if (!row) return []
    const say = (what: string) => () => this.note(`${what}: ${row.text.slice(0, 40) || "(no text)"}`)
    const actions: MessageAction[] = [
      {
        id: "replyInThread",
        label: "Reply in Thread",
        icon: "replyInThread",
        enabled: true,
        quick: true,
        group: "reply",
        run: say("Reply in thread"),
      },
      {
        id: "react",
        label: "Add Reaction",
        icon: "react",
        enabled: row.messageId !== undefined,
        quick: true,
        group: "reply",
        run: (invocation) => {
          // What the app does: a picker anchored at the button, which keeps the row's capsule up while open.
          this.actions.setPickerAnchor(rowId, invocation.anchor)
          this.toggleReaction(rowId, "👍")
          this.note("Toggled 👍; the picker anchor holds the capsule until closePicker()")
        },
      },
      { id: "reply", label: "Reply", icon: "reply", shortcut: "R", enabled: true, group: "reply", run: say("Reply") },
      {
        id: "copy",
        label: "Copy Text",
        icon: "copy",
        shortcut: "⌘C",
        enabled: row.text.length > 0,
        group: "copy",
        run: () => {
          void navigator.clipboard?.writeText(row.text).catch(() => undefined)
          this.note("Copied the text")
        },
      },
      { id: "copyLink", label: "Copy Link", icon: "copyLink", enabled: row.messageId !== undefined, group: "copy", run: say("Copy link") },
    ]
    if (row.out) {
      if (row.state === "failed") {
        actions.push({ id: "resend", label: "Resend", icon: "resend", enabled: true, group: "edit", run: () => this.resend(rowId) })
      }
      actions.push(
        { id: "edit", label: "Edit", icon: "edit", shortcut: "↑", enabled: row.state === "sent", group: "edit", run: say("Edit") },
        { id: "cycle", label: "Next Delivery State (lab)", enabled: true, group: "edit", run: () => this.cycleState(rowId) },
        { id: "delete", label: "Delete", icon: "delete", enabled: true, destructive: true, group: "delete", run: say("Delete") },
      )
    }
    return actions
  }

  // Menu, reactions and picker anchor, for a browser check (`state()`).

  /** Load the menu's code now, as the app's idle lane does. */
  warmMenu(): Promise<void> {
    return this.actions.warmMenu()
  }

  /** Load the emoji names: chips are named "thumbs up, 3, including you" instead of by the emoji. */
  loadEmojiNames(): Promise<unknown> {
    return this.emoji.load()
  }

  closePicker(): void {
    this.actions.setPickerAnchor(null)
  }

  /** A secondary click at a row's center: the browser's menu must be prevented even before the menu's code arrives. */
  rightClick(rowId: MessageRowId): boolean {
    const row = Array.from(document.querySelectorAll("[data-message-row]")).find((el) => el.getAttribute("data-message-row") === rowId)
    if (!row) return false
    const rect = row.getBoundingClientRect()
    const init = { bubbles: true, cancelable: true, button: 2, clientX: rect.x + rect.width / 2, clientY: rect.y + rect.height / 2 }
    row.dispatchEvent(new PointerEvent("pointerdown", { ...init, pointerType: "mouse" }))
    const event = new MouseEvent("contextmenu", init)
    row.dispatchEvent(event)
    return event.defaultPrevented
  }

  /** Plain data: the row menu, the reaction chips, the picker anchor. */
  state() {
    const menus = Array.from(document.querySelectorAll<HTMLElement>("[role=menu]")).filter((menu) => menu.matches(":popover-open"))
    return {
      menu: {
        loaded: this.#menuKit.peek() !== undefined,
        waiting: this.actions.contextMenu.waiting.peek(),
        open: this.actions.contextMenu.isOpen.peek(),
        row: this.actions.menuRowId.peek(),
        items: menus.flatMap((menu) =>
          Array.from(menu.querySelectorAll<HTMLElement>(":scope > [role^=menuitem]")).map((item) => ({
            name: item.getAttribute("aria-label"),
            keyshortcuts: item.getAttribute("aria-keyshortcuts"),
          })),
        ),
      },
      emojiNames: this.emoji.status.peek(),
      chips: Array.from(document.querySelectorAll<HTMLElement>("[role=group][aria-label=Reactions] button")).map((chip) => ({
        row: chip.closest("[data-message-row]")?.getAttribute("data-message-row") ?? null,
        name: chip.getAttribute("aria-label"),
        tooltip: chip.getAttribute("title"),
        pressed: chip.getAttribute("aria-pressed"),
      })),
      picker: this.actions.pickerAnchor.peek(),
      hovered: this.actions.hoveredRowId.peek(),
    }
  }

  dispose(): void {
    this.stopStream()
    this.actions.dispose()
  }
}

const missing: ReadSignal<MessageRow | undefined> = signal<MessageRow | undefined>(undefined)

/** Expose the lab for poking at from the console. */
export const exposeLab = (lab: MessageLab): void => {
  ;(globalThis as { __messageLab?: MessageLab }).__messageLab = lab
}
