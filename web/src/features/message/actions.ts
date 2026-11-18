/**
 * Row actions: the hover and focus quick actions and the context menu of the
 * message list, both driven by one list of actions per row that the caller
 * supplies (the command registry, later). Framework-free.
 *
 * One controller serves a whole list. It tracks which row is hovered or holds
 * focus by delegated events on the list element, exposes a per-row "active"
 * signal (so a hover change re-renders the two rows involved and nothing
 * else), and owns the single context menu, the UI kit's `LazyContextMenu`:
 * rows bind "open a menu here" through its small trigger, and the menu's code
 * (the kit's menu chunk) loads on the first request or when the app warms it.
 * Mac: `MessageQuickActionsView` is one list-owned accessory;
 * `MessageView.createMessageMenu` builds the menu per message.
 */

import type { MessageRowId } from "@inline/core-protocol"
import { computed, type ReadSignal, signal } from "@inline/reactive"
import { LazyContextMenu, type MenuEntry, type MenuKitSource, type Part, type Rect } from "@inline/ui"

/** Icons the row views know how to draw. */
export type MessageActionIcon =
  | "reply"
  | "replyInThread"
  | "react"
  | "copy"
  | "copyLink"
  | "edit"
  | "delete"
  | "resend"
  | "forward"
  | "pin"
  | "select"
  | "more"

export type MessageActionInvocation = {
  readonly rowId: MessageRowId
  /** Where the action was chosen. */
  readonly via: "quick" | "menu"
  /** The control's rectangle, for anchoring a picker (quick actions only). */
  readonly anchor?: Rect
}

export type MessageAction = {
  /** Unique within one row's list. */
  readonly id: string
  readonly label: string
  readonly icon?: MessageActionIcon
  /** Shortcut hint shown in the menu, for example "⌘C". Matching is the command registry's job. */
  readonly shortcut?: string
  /** `aria-keyshortcuts` for it ("Meta+C"); derived from `shortcut` when omitted. */
  readonly keyshortcuts?: string
  readonly enabled: boolean
  readonly destructive?: boolean
  /** Also shown as a quick action on hover and focus, in list order. */
  readonly quick?: boolean
  /** Actions of different groups are separated in the menu. */
  readonly group?: string
  readonly run: (invocation: MessageActionInvocation) => void
}

/**
 * The actions for a row, in menu order. Called while the menu is built (inside
 * a computed: signals it reads are tracked) and when a row becomes active.
 */
export type MessageActionsSource = (rowId: MessageRowId) => readonly MessageAction[]

/** The attribute every message row carries, naming its row ID. */
export const MESSAGE_ROW_ATTRIBUTE = "data-message-row"

/** Menu entries for a row's actions: separators between groups, disabled entries kept. */
export const menuEntries = (actions: readonly MessageAction[], rowId: MessageRowId): MenuEntry[] => {
  const entries: MenuEntry[] = []
  let group: string | undefined
  for (const [index, action] of actions.entries()) {
    if (index > 0 && action.group !== group) entries.push({ type: "separator", id: `separator-${index}` })
    group = action.group
    entries.push({
      type: "item",
      id: action.id,
      label: action.label,
      disabled: !action.enabled,
      ...(action.shortcut ? { shortcut: action.shortcut } : {}),
      ...(action.keyshortcuts ? { keyshortcuts: action.keyshortcuts } : {}),
      ...(action.destructive ? { destructive: true } : {}),
      onSelect: () => action.run({ rowId, via: "menu" }),
    })
  }
  return entries
}

/** The quick actions of a row, in order. */
export const quickActions = (actions: readonly MessageAction[]): readonly MessageAction[] =>
  actions.filter((action) => action.quick === true)

export type MessageActionsOptions = {
  readonly actionsFor: MessageActionsSource
  /** Accessible name of the context menu. Default "Message actions". */
  readonly label?: string
  readonly document?: Document
  /** Where the menu's code comes from. Default the kit's shared menu chunk; tests pass their own. */
  readonly menuKit?: MenuKitSource
}

/** The attribute a quick action button carries, naming its action ID. */
export const QUICK_ACTION_ATTRIBUTE = "data-quick-action"

/** Where a reaction picker for a row is anchored. */
export type ReactionPickerAnchor = { readonly rowId: MessageRowId; readonly rect: Rect }

const ACTIVE_CACHE_LIMIT = 2048

const rowIdOf = (target: EventTarget | null): MessageRowId | null => {
  if (!target || typeof (target as Element).closest !== "function") return null
  const row = (target as Element).closest(`[${MESSAGE_ROW_ATTRIBUTE}]`)
  return row?.getAttribute(MESSAGE_ROW_ATTRIBUTE) ?? null
}

/** Keyboard focus only: a click that focuses something must not pin a row's quick actions. */
const isFocusVisible = (target: EventTarget | null): boolean => {
  if (!target || typeof (target as Element).matches !== "function") return false
  try {
    return (target as Element).matches(":focus-visible")
  } catch {
    return true
  }
}

const isLinkOrEditable = (target: EventTarget | null): boolean => {
  if (!target || typeof (target as Element).closest !== "function") return false
  return (target as Element).closest('a[href], input, textarea, [contenteditable=""], [contenteditable="true"]') !== null
}

export class MessageActionsController {
  readonly #options: MessageActionsOptions
  readonly #hovered = signal<MessageRowId | null>(null)
  readonly #focused = signal<MessageRowId | null>(null)
  readonly #menuRow = signal<MessageRowId | null>(null)
  readonly #picker = signal<ReactionPickerAnchor | null>(null)
  readonly #active = new Map<MessageRowId, ReadSignal<boolean>>()
  #listElement: HTMLElement | null = null

  /** The row whose context menu is open. */
  readonly menuRowId: ReadSignal<MessageRowId | null> = this.#menuRow
  /** The hovered row. */
  readonly hoveredRowId: ReadSignal<MessageRowId | null> = this.#hovered
  /** The row that holds focus. */
  readonly focusedRowId: ReadSignal<MessageRowId | null> = this.#focused
  /** The reaction picker's anchor while one is open for a row (`setPickerAnchor`). */
  readonly pickerAnchor: ReadSignal<ReactionPickerAnchor | null> = this.#picker
  /** The shared row menu. Its code loads on the first request (or `warmMenu()`); a request made meanwhile waits. */
  readonly contextMenu: LazyContextMenu

  constructor(options: MessageActionsOptions) {
    this.#options = options
    this.contextMenu = new LazyContextMenu({
      label: options.label ?? "Message actions",
      ...(options.document ? { document: options.document } : {}),
      ...(options.menuKit ? { kit: options.menuKit } : {}),
      items: () => {
        const rowId = this.#menuRow.get()
        return rowId === null ? [] : menuEntries(options.actionsFor(rowId), rowId)
      },
      shouldOpen: (event) => {
        // Links keep the browser's menu (open in new tab, copy link); so do fields.
        if (isLinkOrEditable(event.target)) return false
        const rowId = rowIdOf(event.target)
        if (rowId === null) return false
        if (options.actionsFor(rowId).length === 0) return false
        this.#menuRow.set(rowId)
        return true
      },
      onOpenChange: (open) => {
        if (!open) this.#menuRow.set(null)
      },
      // The menu's code did not load: the request is dropped, so the row lets go.
      onLoadError: () => this.#menuRow.set(null),
    })
  }

  /** Load the menu's code now (the idle lane), so the first secondary click opens synchronously. */
  warmMenu(): Promise<void> {
    return this.contextMenu.warm()
  }

  /** The actions for a row. */
  actionsFor(rowId: MessageRowId): readonly MessageAction[] {
    return this.#options.actionsFor(rowId)
  }

  /**
   * True while the row is hovered, holds focus, or has its menu open. Cached
   * per row; the cache is dropped wholesale past a bound, and rows simply get
   * a fresh signal on their next render.
   */
  isActive(rowId: MessageRowId): ReadSignal<boolean> {
    let active = this.#active.get(rowId)
    if (!active) {
      if (this.#active.size >= ACTIVE_CACHE_LIMIT) this.#active.clear()
      active = computed(
        () =>
          this.#hovered.get() === rowId ||
          this.#focused.get() === rowId ||
          this.#menuRow.get() === rowId ||
          this.#picker.get()?.rowId === rowId,
      )
      this.#active.set(rowId, active)
    }
    return active
  }

  setHovered(rowId: MessageRowId | null): void {
    this.#hovered.set(rowId)
  }

  setFocused(rowId: MessageRowId | null): void {
    this.#focused.set(rowId)
  }

  /** Open the row's menu at a rectangle (the "more" quick action). */
  openMenu(rowId: MessageRowId, anchor: Rect, options: { keyboard?: boolean } = {}): void {
    if (this.#options.actionsFor(rowId).length === 0) return
    this.contextMenu.close({ restoreFocus: false })
    this.#menuRow.set(rowId)
    this.contextMenu.openAt(anchor, { keyboard: options.keyboard ?? false })
  }

  /**
   * A reaction picker is open for `rowId` at `rect` (or closed: null). While
   * it is, the row stays active, so its quick actions (the picker's anchor)
   * stay on screen when the pointer moves into the picker. The app calls it
   * when it opens and closes the picker.
   */
  setPickerAnchor(rowId: MessageRowId | null, rect?: Rect): void {
    this.#picker.set(rowId === null ? null : { rowId, rect: rect ?? this.reactionAnchor(rowId) ?? { x: 0, y: 0, width: 0, height: 0 } })
  }

  /**
   * Where a reaction picker for `rowId` should point: the row's Add Reaction
   * quick action when it is on screen, else the row's bubble, else the row.
   * Null when the row is not rendered. For a picker opened from the menu or a
   * command (a quick action passes its own rectangle in `run`).
   */
  reactionAnchor(rowId: MessageRowId, actionId = "react"): Rect | null {
    const list = this.#listElement
    if (!list) return null
    const row = Array.from(list.querySelectorAll(`[${MESSAGE_ROW_ATTRIBUTE}]`)).find(
      (element) => element.getAttribute(MESSAGE_ROW_ATTRIBUTE) === rowId,
    )
    if (!row) return null
    const target =
      Array.from(row.querySelectorAll(`[${QUICK_ACTION_ATTRIBUTE}]`)).find(
        (element) => element.getAttribute(QUICK_ACTION_ATTRIBUTE) === actionId,
      ) ??
      row.querySelector("[data-message-bubble]") ??
      row
    const rect = target.getBoundingClientRect()
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
  }

  /** Run a quick action with the control's rectangle as its anchor. */
  runQuick(rowId: MessageRowId, action: MessageAction, anchor?: Rect): void {
    if (!action.enabled) return
    action.run({ rowId, via: "quick", ...(anchor ? { anchor } : {}) })
  }

  /**
   * Attach to the list element (any ancestor of the rows): delegated hover and
   * focus tracking, and secondary click for the context menu.
   */
  readonly list: Part = {
    attach: (element) => {
      const onPointerOver = (event: PointerEvent) => {
        if (event.pointerType === "touch") return
        this.#hovered.set(rowIdOf(event.target))
      }
      const onPointerLeave = () => this.#hovered.set(null)
      const onFocusIn = (event: FocusEvent) =>
        this.#focused.set(isFocusVisible(event.target) ? rowIdOf(event.target) : null)
      const onFocusOut = (event: FocusEvent) => {
        const next = event.relatedTarget
        if (next instanceof Node && element.contains(next)) return
        this.#focused.set(null)
      }
      element.addEventListener("pointerover", onPointerOver)
      element.addEventListener("pointerleave", onPointerLeave)
      element.addEventListener("focusin", onFocusIn)
      element.addEventListener("focusout", onFocusOut)
      const detachMenu = this.contextMenu.target.attach(element)
      this.#listElement = element
      return () => {
        if (this.#listElement === element) this.#listElement = null
        detachMenu()
        element.removeEventListener("pointerover", onPointerOver)
        element.removeEventListener("pointerleave", onPointerLeave)
        element.removeEventListener("focusin", onFocusIn)
        element.removeEventListener("focusout", onFocusOut)
        this.#hovered.set(null)
        this.#focused.set(null)
      }
    },
  }

  dispose(): void {
    this.contextMenu.dispose()
    this.#active.clear()
    this.#picker.set(null)
  }
}
