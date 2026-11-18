/**
 * The sidebar list's controller: windowing, roving focus, keyboard,
 * typeahead, pointer activation, the context menu target and the "unread
 * below" state. Framework-free; the view renders `slotCount` recycled rows
 * (`slot(i)` says which key each shows; see slots.ts) and hands elements to
 * the parts (`scroller`, `listbox`, `slotPart(i)`).
 *
 * What it reads from the model, and nothing else: `items` (the core's
 * order; never reordered here), `item(key)`, `selectedChatId`,
 * `dialogByChat`, `mode`, and it calls `open` and `setMode`.
 *
 * Rows are positioned here, imperatively (`transform`, `aria-posinset`,
 * `tabindex`), so a reorder moves elements without rendering a row body.
 *
 * While the list scrolls faster than half a viewport per event, rows that
 * enter are drawn "lite" (title and avatar color only) and filled in a few
 * per frame once scrolling settles.
 */

import type { RowKey } from "@inline/core-protocol"
import type { ChatID } from "@inline/ids"
import {
  batch,
  computed,
  effect,
  sameKeys,
  signal,
  untracked,
  type Dispose,
  type ReadSignal,
  type Signal,
} from "@inline/reactive"
import {
  combineParts,
  LazyContextMenu,
  systemClock,
  Timer,
  type Clock,
  type MenuEntry,
  type MenuKitSource,
  type Part,
} from "@inline/ui"
import { detectOS, type OpenIntent, type OS } from "@inline/view"
import type { SidebarItem, SidebarMode, SidebarModel } from "@inline/view/features"
import { toMenuEntries, type SidebarActions } from "./actions"
import { sameActivityStatus, type SidebarActivityStatus, type SidebarTypingSource } from "./activity"
import {
  contentHeight,
  DEFAULT_OVERSCAN,
  firstIndexBelow,
  NO_UNREAD_BELOW,
  rowMetrics,
  rowTop,
  sameRange,
  sameUnreadBelow,
  scrollToReveal,
  unreadBelow,
  unreadScrollPlan,
  visibleRange,
  windowKeys,
  type IndexRange,
  type RowMetrics,
  type SidebarDensity,
  type UnreadBelow,
} from "./geometry"
import type { SidebarHandle, SidebarSnapshot } from "./handle"
import {
  listKeyAction,
  moveIndex,
  pointerOpenIntent,
  type KeyInput,
  type OpenIntentMap,
} from "./keyboard"
import { LIST_LABEL } from "./labels"
import { assignSlots, enteringKeys, type SlotKeys } from "./slots"
import { TitleTypeahead } from "./typeahead"

/** The part of `SidebarModel` the list uses. */
export type SidebarSource = Pick<
  SidebarModel,
  "items" | "item" | "selectedChatId" | "dialogByChat" | "open" | "mode" | "setMode"
>

export type SidebarStatus = "loading" | "empty" | "list"

export type SidebarOpenEvent = {
  readonly key: RowKey
  readonly chatId?: ChatID
  readonly intent: OpenIntent
  readonly via: "keyboard" | "pointer"
}

/** Callbacks the view refreshes on every render; read when they fire, never captured. */
export type SidebarCallbacks = {
  readonly actions?: SidebarActions
  /** Compose activity per chat, for the rows (see `activity.ts`). */
  readonly typingFor?: SidebarTypingSource
  readonly onOpened?: (event: SidebarOpenEvent) => void
  readonly openIntent?: OpenIntentMap
}

export type SidebarControllerOptions = {
  readonly model: SidebarSource
  readonly density?: SidebarDensity
  /**
   * True once the core answered the list for the current mode. Until then an
   * empty list is "loading", never "empty", and a mode switch keeps showing
   * the previous list. Without it the list counts as always answered.
   */
  readonly ready?: ReadSignal<boolean>
  readonly handle?: SidebarHandle
  readonly os?: OS
  /** For the typeahead's pause. */
  readonly clock?: Clock
  readonly overscan?: number
  /** Assumed before the scroller is measured, so the first render covers a tall window. */
  readonly initialViewportHeight?: number
  readonly label?: string
  /** Where the context menu's code comes from. Default the kit's shared menu chunk; tests pass their own. */
  readonly menuKit?: MenuKitSource
}

type Keyed = { readonly preventDefault: () => void; readonly defaultPrevented?: boolean }

let nextListId = 1

const prefersReducedMotion = (): boolean =>
  typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches

const EMPTY_INDICES: readonly number[] = Object.freeze([])
const EMPTY_KEYS: ReadonlySet<RowKey> = new Set()
const NO_ITEM: ReadSignal<SidebarItem | undefined> = computed(() => undefined)
const NO_TARGET: ReadSignal<boolean> = computed(() => false)
const NO_ACTIVITY: ReadSignal<SidebarActivityStatus | undefined> = computed(() => undefined)
/** Cached activity signals kept at most; past it the cache is dropped and rows get fresh ones. */
const ACTIVITY_CACHE_LIMIT = 1024

/** A scroll event that moves more than this share of the viewport is fast. */
const FAST_SCROLL_FRACTION = 0.5
/** Fast scrolling ends this long after the last fast event. */
const SETTLE_MS = 120
/** Lite rows filled in per frame after scrolling settles. */
const FILL_PER_FRAME = 8

/** What one recycled row shows. */
export type SlotView = { readonly key: RowKey | undefined; readonly lite: boolean }

const EMPTY_SLOT: SlotView = Object.freeze({ key: undefined, lite: false })

/** After a list change: soon, but in its own task. */
const UNREAD_COUNT_DELAY = 50
/** After scrolling stops: picks up unread changes that did not move a row. */
const UNREAD_SCROLL_DELAY = 250

const sameNumbers = (a: readonly number[], b: readonly number[]) =>
  a === b || (a.length === b.length && a.every((value, index) => value === b[index]))

export class SidebarController {
  readonly model: SidebarSource
  readonly metrics: RowMetrics
  readonly density: SidebarDensity
  readonly os: OS
  readonly label: string
  /** The listbox's ID; option IDs derive from it. */
  readonly listId: string

  readonly mode: ReadSignal<SidebarMode>
  /** The keys shown: the model's list, or the previous one while a new mode loads. */
  readonly displayKeys: ReadSignal<readonly RowKey[]>
  readonly status: ReadSignal<SidebarStatus>
  /** True while the shown list is not the current mode's answer. */
  readonly busy: ReadSignal<boolean>
  /** The row of the chat shown in the focused pane, if it is in the list. */
  readonly selectedKey: ReadSignal<RowKey | undefined>
  /** The roving tab stop: the focused row while the list has focus, else the selected row. */
  readonly currentKey: ReadSignal<RowKey | undefined>
  readonly hasFocus: ReadSignal<boolean>
  readonly range: ReadSignal<IndexRange>
  /** The rows to show, in list order: the visible range plus the current row. */
  readonly windowKeys: ReadSignal<readonly RowKey[]>
  /** Which key each recycled row shows; a key keeps its slot while it stays in the window. */
  readonly slotKeys: ReadSignal<SlotKeys>
  /** How many recycled rows the list renders. Grows with the window; rarely shrinks. */
  readonly slotCount: ReadSignal<number>
  readonly contentHeight: ReadSignal<number>
  /** Prominent unread rows below the viewport. Tracking starts after the first paint. */
  readonly unreadBelow: ReadSignal<UnreadBelow>
  /**
   * The row menu. Its code (the kit's menu) loads on the first secondary
   * click or when warmed; the request is kept until then.
   */
  readonly contextMenu: LazyContextMenu
  /** The row the context menu is open for. */
  readonly contextKey: ReadSignal<RowKey | undefined>

  #callbacks: SidebarCallbacks = {}
  readonly #activitySignals = new Map<RowKey, ReadSignal<SidebarActivityStatus | undefined>>()
  readonly #ready: ReadSignal<boolean>
  readonly #scrollTop = signal(0)
  readonly #viewportHeight: Signal<number>
  readonly #focused = signal<RowKey | undefined>(undefined)
  readonly #hasFocus = signal(false)
  readonly #contextKey = signal<RowKey | undefined>(undefined)
  readonly #unreadEnabled = signal(false)
  readonly #unreadIndices = signal<readonly number[]>(EMPTY_INDICES, { equals: sameNumbers })
  readonly #unreadTimer: Timer
  readonly #unreadScrollTimer: Timer
  readonly #index: ReadSignal<ReadonlyMap<RowKey, number>>
  readonly #typeahead: TitleTypeahead
  readonly #slotElements: (HTMLElement | undefined)[] = []
  readonly #slotOfElement = new WeakMap<Element, number>()
  readonly #slotParts: Part[] = []
  readonly #slotViews: ReadSignal<SlotView>[] = []
  readonly #slotIndex: ReadSignal<ReadonlyMap<RowKey, number>>
  readonly #lite = signal<ReadonlySet<RowKey>>(EMPTY_KEYS)
  readonly #settleTimer: Timer
  readonly #fillTimer: Timer
  #fast = false
  #fillFrame: number | undefined
  readonly #contextSignals = new Map<RowKey, ReadSignal<boolean>>()
  readonly #disposers: Dispose[] = []
  #scroller: HTMLElement | null = null
  #listbox: HTMLElement | null = null
  #pendingFocus: RowKey | undefined
  #focusHint = 0
  #disposed = false

  constructor(options: SidebarControllerOptions) {
    this.model = options.model
    this.density = options.density ?? "standard"
    this.metrics = rowMetrics(this.density)
    this.os = options.os ?? detectOS(typeof navigator === "undefined" ? undefined : navigator)
    this.label = options.label ?? LIST_LABEL
    this.listId = `sidebar-list-${nextListId++}`
    this.#ready = options.ready ?? computed(() => true)
    this.#viewportHeight = signal(options.initialViewportHeight ?? 900)
    this.#typeahead = new TitleTypeahead(options.clock ? { clock: options.clock } : {})
    this.#unreadTimer = new Timer(options.clock ?? systemClock)
    this.#unreadScrollTimer = new Timer(options.clock ?? systemClock)
    this.#settleTimer = new Timer(options.clock ?? systemClock)
    this.#fillTimer = new Timer(options.clock ?? systemClock)
    this.mode = this.model.mode
    this.hasFocus = this.#hasFocus
    this.contextKey = this.#contextKey
    const overscan = options.overscan ?? DEFAULT_OVERSCAN
    const rowHeight = this.metrics.rowHeight

    // A mode switch empties the model's list until the core answers; keep the
    // previous list on screen meanwhile instead of flashing empty.
    let held: readonly RowKey[] = this.model.items.peek()
    this.displayKeys = computed(
      () => {
        const keys = this.model.items.get()
        if (keys.length > 0 || this.#ready.get()) {
          held = keys
          return keys
        }
        return held
      },
      { equals: sameKeys },
    )
    this.status = computed(() => {
      if (this.displayKeys.get().length > 0) return "list"
      return this.#ready.get() ? "empty" : "loading"
    })
    this.busy = computed(() => !this.#ready.get())
    this.#index = computed(() => {
      const map = new Map<RowKey, number>()
      const keys = this.displayKeys.get()
      for (let index = 0; index < keys.length; index++) map.set(keys[index]!, index)
      return map
    })
    this.selectedKey = computed(() => {
      const chatId = this.model.selectedChatId.get()
      if (chatId === undefined) return undefined
      const key = this.model.dialogByChat.get().get(chatId)
      return key !== undefined && this.#index.get().has(key) ? key : undefined
    })
    this.currentKey = computed(() => {
      const index = this.#index.get()
      const focused = this.#focused.get()
      if (this.#hasFocus.get() && focused !== undefined && index.has(focused)) return focused
      const selected = this.selectedKey.get()
      if (selected !== undefined) return selected
      if (focused !== undefined && index.has(focused)) return focused
      return this.displayKeys.get()[0]
    })
    this.range = computed(
      () =>
        visibleRange(
          { scrollTop: this.#scrollTop.get(), height: this.#viewportHeight.get() },
          this.displayKeys.get().length,
          rowHeight,
          overscan,
        ),
      { equals: sameRange },
    )
    this.windowKeys = computed(
      () => {
        const current = this.currentKey.get()
        const extra = current === undefined ? undefined : this.#index.get().get(current)
        return windowKeys(this.displayKeys.get(), this.range.get(), extra)
      },
      { equals: sameKeys },
    )
    let slots: SlotKeys = []
    this.slotKeys = computed(() => {
      slots = assignSlots(slots, this.windowKeys.get())
      return slots
    })
    this.slotCount = computed(() => this.slotKeys.get().length)
    this.#slotIndex = computed(() => {
      const map = new Map<RowKey, number>()
      this.slotKeys.get().forEach((key, slot) => {
        if (key !== undefined) map.set(key, slot)
      })
      return map
    })
    this.contentHeight = computed(() => contentHeight(this.displayKeys.get().length, rowHeight))

    // Every prominent unread row's index, counted off the critical path: it
    // reads every item, and every item depends on the selection, so a
    // tracked count would re-derive thousands of items in the frame that
    // paints a chat switch. Recounted a moment after the list changes and
    // after scrolling stops (see `#scheduleUnreadCount`).
    this.unreadBelow = computed(
      () => {
        const indices = this.#unreadIndices.get()
        if (indices.length === 0) return NO_UNREAD_BELOW
        const viewport = { scrollTop: this.#scrollTop.get(), height: this.#viewportHeight.get() }
        return unreadBelow(indices, firstIndexBelow(viewport, rowHeight))
      },
      { equals: sameUnreadBelow },
    )

    this.contextMenu = new LazyContextMenu({
      label: "Chat actions",
      ...(options.menuKit ? { kit: options.menuKit } : {}),
      items: () => this.#menuEntries(),
      shouldOpen: (event) => this.#shouldOpenMenu(event),
      onOpenChange: (open) => {
        if (!open) this.#contextKey.set(undefined)
      },
      // The menu's code did not load: the request is dropped, so is the row's ring.
      onLoadError: () => this.#contextKey.set(undefined),
    })

    // Position, number and tab-index every mounted row when the list, the
    // current row or the count changes. Rows never re-render for this.
    this.#disposers.push(
      effect(() => {
        const slotKeys = this.slotKeys.get()
        const index = this.#index.get()
        const count = this.displayKeys.get().length
        const current = this.currentKey.get()
        untracked(() => {
          slotKeys.forEach((key, slot) => {
            const element = this.#slotElements[slot]
            if (element) this.#place(element, key, index, count, current)
          })
        })
      }),
    )
    // The focused row left the list (closed, archived, a mode switch): its
    // element now shows another chat or nothing. Move focus to the neighbor.
    this.#disposers.push(
      effect(() => {
        const index = this.#index.get()
        untracked(() => {
          const focused = this.#focused.peek()
          if (this.#hasFocus.peek() && focused !== undefined && !index.has(focused)) {
            queueMicrotask(() => this.#restoreFocus())
          }
        })
      }),
    )
    this.#disposers.push(
      effect(() => {
        if (!this.#unreadEnabled.get()) return
        this.displayKeys.get()
        untracked(() => this.#scheduleUnreadCount(this.#unreadTimer, UNREAD_COUNT_DELAY))
      }),
      effect(() => {
        if (!this.#unreadEnabled.get()) return
        this.#scrollTop.get()
        untracked(() => this.#scheduleUnreadCount(this.#unreadScrollTimer, UNREAD_SCROLL_DELAY))
      }),
      () => {
        this.#unreadTimer.stop()
        this.#unreadScrollTimer.stop()
        this.#settleTimer.stop()
        this.#fillTimer.stop()
        if (this.#fillFrame !== undefined) cancelAnimationFrame(this.#fillFrame)
      },
    )
    // Reveal the selected chat when the selection changes from elsewhere
    // (next and previous chat, a link), as the Mac sidebar does.
    this.#disposers.push(
      effect(() => {
        const key = this.selectedKey.get()
        untracked(() => {
          if (key !== undefined && !this.#hasFocus.peek()) this.#revealKey(key)
        })
      }),
    )
    if (options.handle) {
      this.#disposers.push(
        options.handle.bind({
          focus: () => this.focus(),
          revealSelected: () => this.revealSelected(),
          snapshot: () => this.snapshot(),
        }),
      )
    }
  }

  // MARK: Callbacks and parts

  /** The view calls this on every render with the latest props. */
  setCallbacks(callbacks: SidebarCallbacks): void {
    this.#callbacks = callbacks
  }

  /**
   * The compose activity a row shows for `key`, per key so a change renders
   * that row alone. Undefined while nobody composes, or without `typingFor`.
   * Equal statuses keep the value, so a refresh of the same activity renders
   * nothing.
   */
  activityOf(key: RowKey | undefined): ReadSignal<SidebarActivityStatus | undefined> {
    if (key === undefined) return NO_ACTIVITY
    let cached = this.#activitySignals.get(key)
    if (!cached) {
      if (this.#activitySignals.size >= ACTIVITY_CACHE_LIMIT) this.#activitySignals.clear()
      cached = computed(
        () => {
          const source = this.#callbacks.typingFor
          if (!source) return undefined
          const item = this.model.item(key).get()
          if (!item) return undefined
          return source(item)?.get()?.status
        },
        { equals: sameActivityStatus },
      )
      this.#activitySignals.set(key, cached)
    }
    return cached
  }

  /** Whether `key`'s row is the context menu's target, per key so one row re-renders. */
  isContextTarget(key: RowKey): ReadSignal<boolean> {
    let cached = this.#contextSignals.get(key)
    if (!cached) {
      if (this.#contextSignals.size > 512) {
        // Keep the ones mounted rows use; the rest are recreated on demand.
        for (const cachedKey of this.#contextSignals.keys()) {
          if (!this.#slotIndex.peek().has(cachedKey)) this.#contextSignals.delete(cachedKey)
        }
      }
      cached = computed(() => this.#contextKey.get() === key)
      this.#contextSignals.set(key, cached)
    }
    return cached
  }

  /** The context-target flag for a slot's key, or a constant false for an empty slot. */
  contextTargetOf(key: RowKey | undefined): ReadSignal<boolean> {
    return key === undefined ? NO_TARGET : this.isContextTarget(key)
  }

  /** The item signal for a slot's key, or a constant undefined for an empty slot. */
  itemOf(key: RowKey | undefined): ReadSignal<SidebarItem | undefined> {
    return key === undefined ? NO_ITEM : this.model.item(key)
  }

  /** What recycled row `slot` shows. Per slot, so a slot re-renders only when its key or lite flag changes. */
  slot(slot: number): ReadSignal<SlotView> {
    let view = this.#slotViews[slot]
    if (!view) {
      view = computed(
        () => {
          const key = this.slotKeys.get()[slot]
          if (key === undefined) return EMPTY_SLOT
          return { key, lite: this.#lite.get().has(key) }
        },
        { equals: (a, b) => a.key === b.key && a.lite === b.lite },
      )
      this.#slotViews[slot] = view
    }
    return view
  }

  /** The option element of recycled row `slot`. Stable per slot. */
  slotPart(slot: number): Part {
    let part = this.#slotParts[slot]
    if (!part) {
      part = { attach: (element) => this.#attachSlot(slot, element) }
      this.#slotParts[slot] = part
    }
    return part
  }

  /** The scrolling element. */
  readonly scroller: Part = { attach: (element) => this.#attachScroller(element) }

  /** The listbox element: keyboard, focus, clicks and the context menu target. */
  readonly listbox: Part = combineParts({ attach: (element) => this.#attachListbox(element) }, {
    attach: (element) => this.contextMenu.target.attach(element),
  })

  // MARK: Commands

  /** Focus the current row (the "focus sidebar" command). */
  focus(): boolean {
    const key = this.currentKey.peek()
    if (key === undefined) {
      this.#listbox?.focus({ preventScroll: true })
      return this.#listbox !== null
    }
    return this.focusKey(key)
  }

  /** Move keyboard focus to `key`'s row, scrolling it into view. */
  focusKey(key: RowKey): boolean {
    const index = this.#index.peek().get(key)
    if (index === undefined || this.#disposed) return false
    this.#focusHint = index
    batch(() => {
      this.#focused.set(key)
      this.#hasFocus.set(true)
    })
    this.#reveal(index)
    const element = this.#elementOf(key)
    if (element) {
      this.#pendingFocus = undefined
      element.focus({ preventScroll: true })
    } else {
      // A new slot, mounted by the next render (the current row is always in the window).
      this.#pendingFocus = key
    }
    return true
  }

  revealSelected(): boolean {
    const key = this.selectedKey.peek()
    return key !== undefined && this.#revealKey(key)
  }

  /** Open `key`'s chat. Keyboard focus stays where it is; `onOpened` may move it. */
  activate(key: RowKey, intent: OpenIntent, via: SidebarOpenEvent["via"]): void {
    const item = this.model.item(key).peek()
    this.model.open(key, intent)
    this.#callbacks.onOpened?.({ key, ...(item ? { chatId: item.chatId } : {}), intent, via })
  }

  setMode(mode: SidebarMode): void {
    this.#typeahead.reset()
    this.model.setMode(mode)
  }

  /**
   * A key pressed in the list. Returns true (and prevents the default) when
   * the list handled it. Keys it does not handle reach the app's shortcuts.
   */
  handleKeyDown(event: KeyInput & Keyed): boolean {
    if (event.defaultPrevented) return false
    const action = listKeyAction(event, {
      os: this.os,
      typeaheadActive: this.#typeahead.active,
      ...(this.#callbacks.openIntent ? { openIntent: this.#callbacks.openIntent } : {}),
    })
    if (!action) return false
    const keys = this.displayKeys.peek()
    const current = this.currentKey.peek()
    const currentIndex = current === undefined ? -1 : (this.#index.peek().get(current) ?? -1)
    switch (action.kind) {
      case "move": {
        this.#typeahead.reset()
        const page = Math.floor(this.#viewportHeight.peek() / this.metrics.rowHeight) - 1
        const next = moveIndex(action.to, currentIndex, keys.length, page)
        const key = keys[next]
        if (key !== undefined) this.focusKey(key)
        event.preventDefault()
        return true
      }
      case "open": {
        this.#typeahead.reset()
        if (current === undefined) return false
        event.preventDefault()
        this.activate(current, action.intent, "keyboard")
        return true
      }
      case "type": {
        event.preventDefault()
        const match = this.#typeahead.type(
          action.char,
          keys.length,
          (index) => {
            const key = keys[index]
            return key === undefined ? undefined : this.model.item(key).peek()?.title
          },
          currentIndex,
        )
        const key = keys[match]
        if (key !== undefined) this.focusKey(key)
        return true
      }
    }
  }

  /**
   * Make `key` the context menu's row, as a secondary click on it does.
   * False when the caller gave no actions for it (the browser's menu shows).
   */
  targetMenu(key: RowKey): boolean {
    const actions = this.#callbacks.actions
    const item = this.model.item(key).peek()
    if (!actions || !item || actions(item).length === 0) return false
    this.#contextKey.set(key)
    return true
  }

  /** Scroll to the nearest prominent unread row below the viewport, centered (Mac). */
  revealUnreadBelow(): boolean {
    const target = this.unreadBelow.peek().target
    if (target === undefined) return false
    const rowHeight = this.metrics.rowHeight
    const top = rowTop(target, rowHeight)
    const plan = unreadScrollPlan({
      currentOffset: this.#scrollTop.peek(),
      targetTop: top,
      targetBottom: top + rowHeight,
      viewportHeight: this.#viewportHeight.peek(),
      contentHeight: this.contentHeight.peek(),
    })
    const scroller = this.#scroller
    if (!scroller || prefersReducedMotion()) {
      this.#scrollTo(plan.targetOffset)
      return true
    }
    if (plan.usesLongDistanceJump) this.#scrollTo(plan.animatedStartOffset)
    scroller.scrollTo({ top: plan.targetOffset, behavior: "smooth" })
    return true
  }

  /**
   * A scroll event at `top`. A move of more than half the viewport marks the
   * scroll fast: rows entering the window are drawn lite until it settles.
   */
  scrolled(top: number): void {
    const height = this.#viewportHeight.peek()
    const delta = Math.abs(top - this.#scrollTop.peek())
    if (height > 0 && delta > height * FAST_SCROLL_FRACTION) this.#fast = true
    if (this.#fast) this.#settleTimer.start(SETTLE_MS, () => this.#settle())
    batch(() => {
      const before = this.slotKeys.peek()
      this.#scrollTop.set(top)
      if (!this.#fast) return
      const entering = enteringKeys(before, this.slotKeys.peek())
      if (entering.length === 0) return
      const lite = new Set(this.#lite.peek())
      for (const key of entering) lite.add(key)
      this.#lite.set(lite)
    })
  }

  /** The scroll position and height, as the scroller reports them. Tests call it directly. */
  setViewport(scrollTop: number, height: number): void {
    batch(() => {
      this.#scrollTop.set(scrollTop)
      this.#viewportHeight.set(height)
    })
  }

  /** Start tracking unread rows below the viewport. The scroller does it after the first paint. */
  trackUnreadBelow(): void {
    this.#unreadEnabled.set(true)
  }

  /** Plain data for labs and tests. */
  snapshot(): SidebarSnapshot {
    return {
      count: this.displayKeys.peek().length,
      status: this.status.peek(),
      range: this.range.peek(),
      rendered: this.windowKeys.peek().length,
      currentKey: this.currentKey.peek(),
      selectedKey: this.selectedKey.peek(),
      hasFocus: this.#hasFocus.peek(),
      unreadBelow: this.unreadBelow.peek(),
      contextKey: this.#contextKey.peek(),
      typeahead: this.#typeahead.buffer,
      slots: this.slotCount.peek(),
      lite: this.#lite.peek().size,
      fast: this.#fast,
    }
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    for (const dispose of this.#disposers.splice(0)) dispose()
    this.#typeahead.reset()
    this.contextMenu.dispose()
    this.#slotElements.length = 0
    this.#contextSignals.clear()
    this.#activitySignals.clear()
  }

  // MARK: Internals

  #indexOf(key: RowKey | undefined): number {
    return key === undefined ? -1 : (this.#index.peek().get(key) ?? -1)
  }

  #revealKey(key: RowKey): boolean {
    const index = this.#indexOf(key)
    if (index < 0) return false
    this.#reveal(index)
    return true
  }

  #reveal(index: number): void {
    const top = scrollToReveal(
      index,
      { scrollTop: this.#scrollTop.peek(), height: this.#viewportHeight.peek() },
      this.displayKeys.peek().length,
      this.metrics.rowHeight,
    )
    if (top !== undefined) this.#scrollTo(top)
  }

  #scrollTo(top: number): void {
    // The signal moves at once so the window includes the target in this task.
    this.#scrollTop.set(top)
    if (this.#scroller) this.#scroller.scrollTop = top
  }

  #elementOf(key: RowKey): HTMLElement | undefined {
    const slot = this.#slotIndex.peek().get(key)
    return slot === undefined ? undefined : this.#slotElements[slot]
  }

  /** Point a recycled element at `key`: position, numbering, ID, tab stop. An empty slot is hidden by the view. */
  #place(
    element: HTMLElement,
    key: RowKey | undefined,
    index: ReadonlyMap<RowKey, number>,
    count: number,
    current: RowKey | undefined,
  ): void {
    const position = key === undefined ? undefined : index.get(key)
    if (key === undefined || position === undefined) {
      element.tabIndex = -1
      element.removeAttribute("id")
      element.removeAttribute("aria-posinset")
      delete element.dataset.sidebarKey
      return
    }
    element.style.transform = `translateY(${rowTop(position, this.metrics.rowHeight)}px)`
    element.id = `${this.listId}-${key}`
    element.dataset.sidebarKey = key
    element.setAttribute("aria-posinset", String(position + 1))
    element.setAttribute("aria-setsize", String(count))
    element.tabIndex = key === current ? 0 : -1
  }

  #attachSlot(slot: number, element: HTMLElement): Dispose {
    this.#slotElements[slot] = element
    this.#slotOfElement.set(element, slot)
    element.setAttribute("role", "option")
    const key = this.slotKeys.peek()[slot]
    this.#place(element, key, this.#index.peek(), this.displayKeys.peek().length, this.currentKey.peek())
    if (key !== undefined && this.#pendingFocus === key) {
      this.#pendingFocus = undefined
      element.focus({ preventScroll: true })
    }
    return () => {
      const hadFocus = element.ownerDocument.activeElement === element
      if (this.#slotElements[slot] === element) this.#slotElements[slot] = undefined
      // A trimmed slot that had focus: keep focus in the list.
      if (hadFocus && !this.#disposed) queueMicrotask(() => this.#restoreFocus())
    }
  }

  /** Fast scrolling ended: fill lite rows in, a few per frame, visible ones first. */
  #settle(): void {
    this.#fast = false
    this.#scheduleFill()
  }

  #scheduleFill(): void {
    if (this.#disposed || this.#fillFrame !== undefined || this.#fillTimer.running) return
    const step = () => {
      this.#fillFrame = undefined
      this.#fillStep()
    }
    if (typeof requestAnimationFrame === "function") this.#fillFrame = requestAnimationFrame(step)
    else this.#fillTimer.start(16, step)
  }

  #fillStep(): void {
    if (this.#disposed || this.#fast) return
    const lite = this.#lite.peek()
    if (lite.size === 0) return
    const shown = this.#slotIndex.peek()
    const visible = visibleRange(
      { scrollTop: this.#scrollTop.peek(), height: this.#viewportHeight.peek() },
      this.displayKeys.peek().length,
      this.metrics.rowHeight,
      0,
    )
    const index = this.#index.peek()
    const order = [...lite]
      .filter((key) => shown.has(key))
      .sort((a, b) => {
        const rank = (key: RowKey) => {
          const at = index.get(key) ?? Infinity
          return at >= visible.first && at < visible.last ? at : at + 1e9
        }
        return rank(a) - rank(b)
      })
    // Keys that left the window are dropped from the set too.
    const next = new Set(order.slice(FILL_PER_FRAME))
    this.#lite.set(next.size === 0 ? EMPTY_KEYS : next)
    if (next.size > 0) this.#scheduleFill()
  }

  /** Each timer debounces its own trigger: list changes, scrolling. */
  #scheduleUnreadCount(timer: Timer, delay: number): void {
    if (this.#disposed) return
    timer.start(delay, () => this.#countUnread())
  }

  /** Untracked: peeks every item once. Runs on a timer, never inside a frame's patch. */
  #countUnread(): void {
    if (this.#disposed) return
    const keys = this.displayKeys.peek()
    const indices: number[] = []
    untracked(() => {
      for (let index = 0; index < keys.length; index++) {
        const item = this.model.item(keys[index]!).peek()
        if (item?.hasUnread && item.prominent) indices.push(index)
      }
    })
    this.#unreadIndices.set(indices)
  }

  #restoreFocus(): void {
    if (this.#disposed || !this.#listbox || !this.#hasFocus.peek()) return
    const doc = this.#listbox.ownerDocument
    const active = doc.activeElement
    // Focus went somewhere else on purpose: leave it.
    if (active && active !== doc.body && !this.#listbox.contains(active)) return
    const keys = this.displayKeys.peek()
    if (keys.length === 0) {
      this.#listbox.focus({ preventScroll: true })
      return
    }
    const focused = this.#focused.peek()
    const key = focused !== undefined && this.#index.peek().has(focused)
      ? focused
      : keys[Math.min(this.#focusHint, keys.length - 1)]
    if (key !== undefined) this.focusKey(key)
  }

  #attachScroller(element: HTMLElement): Dispose {
    this.#scroller = element
    const wanted = this.#scrollTop.peek()
    if (wanted > 0) element.scrollTop = wanted
    this.setViewport(element.scrollTop, element.clientHeight)
    const onScroll = () => this.scrolled(element.scrollTop)
    element.addEventListener("scroll", onScroll, { passive: true })
    const resize =
      typeof ResizeObserver === "function"
        ? new ResizeObserver(() => this.#viewportHeight.set(element.clientHeight))
        : undefined
    resize?.observe(element)
    // Unread tracking reads every item; start it after the first paint.
    let timer: ReturnType<typeof setTimeout> | undefined
    const frame =
      typeof requestAnimationFrame === "function"
        ? requestAnimationFrame(() => {
            timer = setTimeout(() => this.trackUnreadBelow(), 0)
          })
        : undefined
    if (frame === undefined) timer = setTimeout(() => this.trackUnreadBelow(), 0)
    return () => {
      element.removeEventListener("scroll", onScroll)
      resize?.disconnect()
      if (frame !== undefined) cancelAnimationFrame(frame)
      if (timer !== undefined) clearTimeout(timer)
      if (this.#scroller === element) this.#scroller = null
    }
  }

  #attachListbox(element: HTMLElement): Dispose {
    this.#listbox = element
    element.id = this.listId
    element.setAttribute("role", "listbox")
    element.setAttribute("aria-label", this.label)
    element.setAttribute("aria-orientation", "vertical")
    element.tabIndex = -1
    const onKeyDown = (event: KeyboardEvent) => {
      if (this.handleKeyDown(event)) event.stopPropagation()
    }
    const onClick = (event: MouseEvent) => this.#onPointerActivate(event)
    const onMouseDown = (event: MouseEvent) => {
      // No middle-button autoscroll over rows; auxclick opens in a new tab.
      if (event.button === 1 && this.#keyFromTarget(event.target) !== undefined) event.preventDefault()
    }
    const onFocusIn = (event: FocusEvent) => {
      const key = this.#keyFromTarget(event.target)
      if (key !== undefined) {
        this.#focusHint = this.#indexOf(key)
        batch(() => {
          this.#focused.set(key)
          this.#hasFocus.set(true)
        })
        return
      }
      // Focus landed on the list itself (a click between rows): move it to the current row.
      if (event.target === element && this.currentKey.peek() !== undefined) this.focus()
      else this.#hasFocus.set(true)
    }
    const onFocusOut = (event: FocusEvent) => {
      const next = event.relatedTarget
      if (next instanceof Node && element.contains(next)) return
      this.#typeahead.reset()
      this.#hasFocus.set(false)
    }
    element.addEventListener("keydown", onKeyDown)
    element.addEventListener("click", onClick)
    element.addEventListener("auxclick", onClick)
    element.addEventListener("mousedown", onMouseDown)
    element.addEventListener("focusin", onFocusIn)
    element.addEventListener("focusout", onFocusOut)
    return () => {
      element.removeEventListener("keydown", onKeyDown)
      element.removeEventListener("click", onClick)
      element.removeEventListener("auxclick", onClick)
      element.removeEventListener("mousedown", onMouseDown)
      element.removeEventListener("focusin", onFocusIn)
      element.removeEventListener("focusout", onFocusOut)
      if (this.#listbox === element) this.#listbox = null
    }
  }

  #onPointerActivate(event: MouseEvent): void {
    if (event.defaultPrevented) return
    const key = this.#keyFromTarget(event.target)
    if (key === undefined) return
    const intent = pointerOpenIntent(event, this.os, this.#callbacks.openIntent)
    if (intent === undefined) return
    if (intent !== "here") event.preventDefault()
    this.activate(key, intent, "pointer")
  }

  #keyFromTarget(target: EventTarget | null): RowKey | undefined {
    let node = target instanceof Element ? target : null
    while (node && node !== this.#listbox) {
      const slot = this.#slotOfElement.get(node)
      if (slot !== undefined) return this.slotKeys.peek()[slot]
      node = node.parentElement
    }
    return undefined
  }

  #shouldOpenMenu(event: Event): boolean {
    const key = this.#keyFromTarget(event.target)
    return key !== undefined && this.targetMenu(key)
  }

  #menuEntries(): MenuEntry[] {
    const key = this.#contextKey.get()
    if (key === undefined) return []
    const item: SidebarItem | undefined = this.model.item(key).get()
    const actions = this.#callbacks.actions
    if (!item || !actions) return []
    return toMenuEntries(untracked(() => actions(item)))
  }
}
