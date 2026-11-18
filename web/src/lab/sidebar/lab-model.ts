/**
 * The sidebar lab's model: a real `SidebarModel` over the real store client
 * and scheduler, fed by `LabCore` through the scripted endpoint. It runs the
 * operations, measures what each one rendered, and publishes plain state on
 * `globalThis.__sidebarLab` and functions on `globalThis.__sidebarLabControl`.
 *
 * "Rows rendered by the last operation": the render counter is reset, the
 * operation runs, and the count is read after the frame lane applied the
 * patch and React committed (a frame, then a task).
 */

import type { RowKey } from "@inline/core-protocol"
import {
  browserScheduler,
  computed,
  createStoreClient,
  effect,
  signal,
  type ReadSignal,
  type Scheduler,
  type StoreClient,
  untracked,
} from "@inline/reactive"
import type { RenderCounter } from "@inline/reactive/react/testing"
import { Workspace, type OpenIntent } from "@inline/view"
import { SidebarModel, type SidebarItem, type SidebarMode } from "@inline/view/features"
import {
  basicActions,
  SidebarHandle,
  type SidebarAction,
  type SidebarActivity,
  type SidebarActivityStatus,
  type SidebarDensity,
  type UnreadStyle,
} from "../../features/sidebar"
import type { ChatID } from "@inline/ids"
import type { Signal } from "@inline/reactive"
import { LabCore, type Latency } from "./lab-core"

export type LabTheme = "system" | "light" | "dark"
export type LabDir = "ltr" | "rtl"

export type OperationResult = {
  readonly name: string
  /** `SidebarRow` bodies rendered. */
  readonly rows: number
  /** `SidebarList` renders. */
  readonly lists: number
  /** Every counted component. */
  readonly total: number
  /** From the call to the commit, including the frame wait. */
  readonly ms: number
}

export type ScrollResult = {
  readonly frames: number
  /** Pixels moved per frame. */
  readonly step: number
  /** Gap between consecutive animation frames. */
  readonly frameMs: { readonly median: number; readonly p95: number; readonly max: number }
  /**
   * Script per frame: from the scroll event to the next animation frame
   * callback, which covers the list's scroll handling and React's commit
   * (not style, layout or paint).
   */
  readonly scriptMs: { readonly median: number; readonly p95: number; readonly max: number }
  /** `long-animation-frame` entries (frames over 50 ms), where the browser reports them. */
  readonly longFrames: { readonly supported: boolean; readonly count: number; readonly maxMs: number; readonly scriptMs: number }
  readonly rowsRendered: number
  readonly maxRowsInOneFrame: number
  /** Rows rendered while lite rows were filled in after the scroll stopped. */
  readonly fillRows: number
  /** Visible options in the DOM at most (empty spare slots are hidden and not counted). */
  readonly maxRenderedAtOnce: number
}

type LongFrameEntry = PerformanceEntry & { readonly scripts?: readonly { readonly duration: number }[] }

const stats = (values: readonly number[]) => {
  const sorted = [...values].sort((a, b) => a - b)
  const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0
  const round = (value: number) => Math.round(value * 10) / 10
  return { median: round(at(0.5)), p95: round(at(0.95)), max: round(sorted[sorted.length - 1] ?? 0) }
}

/** A session: core, client, workspace and model. Rebuilt by `restart`. */
type Session = {
  readonly core: LabCore
  readonly client: StoreClient
  readonly scheduler: Scheduler
  readonly workspace: Workspace
  readonly model: SidebarModel
}

const nextFrame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()))
const nextTask = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

/** The open menu's items (the row menu and its open submenu), for a browser check. */
const openMenuEntries = () =>
  Array.from(document.querySelectorAll<HTMLElement>("[role=menu]"))
    .filter((menu) => menu.matches(":popover-open"))
    .map((menu) =>
      Array.from(menu.querySelectorAll<HTMLElement>(":scope > [role^=menuitem]")).map((item) => ({
        role: item.getAttribute("role"),
        name: item.getAttribute("aria-label"),
        checked: item.getAttribute("aria-checked"),
        keyshortcuts: item.getAttribute("aria-keyshortcuts"),
      })),
    )

export const applyTheme = (theme: LabTheme) => {
  document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
}
export const applyDir = (dir: LabDir) => {
  document.documentElement.dir = dir
}

export class SidebarLab {
  readonly counter: RenderCounter
  readonly handle = new SidebarHandle()
  readonly session = signal<Session>(undefined as unknown as Session)
  readonly density = signal<SidebarDensity>("standard")
  readonly unreadStyle = signal<UnreadStyle>("count")
  readonly theme = signal<LabTheme>("system")
  readonly dir = signal<LabDir>("ltr")
  readonly latency = signal<Latency>(0)
  readonly chrome = signal(true)
  /** List position (1-based) the row operations act on. */
  readonly position = signal(4)
  readonly lastOp = signal<OperationResult | undefined>(undefined)
  readonly lastScroll = signal<ScrollResult | undefined>(undefined)
  readonly log = signal<readonly string[]>([])
  readonly ready: ReadSignal<boolean>
  #count = 300
  #busy: Promise<unknown> = Promise.resolve()

  constructor(counter: RenderCounter, count = 300) {
    this.counter = counter
    this.#count = count
    this.session.set(this.#createSession())
    this.ready = computed(() => this.session.get().core.ready.get())
    effect(() => {
      const session = this.session.get()
      session.model.selectedChatId.get()
      session.model.mode.get()
      session.core.ready.get()
      this.lastOp.get()
      this.density.get()
      // Off the measured task: publishing reads the controller's state.
      untracked(() => this.#schedulePublish())
    })
  }

  get model(): SidebarModel {
    return this.session.peek().model
  }

  // MARK: Operations

  /** The chat number at list position `position` (1-based) in the current list. */
  chatAt(position = this.position.peek()): number | undefined {
    const key = this.model.items.peek()[position - 1]
    return key === undefined ? undefined : this.session.peek().core.chatByDialogKey(key)?.n
  }

  newMessage(position?: number) {
    return this.#run("new message", () => this.#withChat(position, (n, core) => core.newMessage(n)))
  }

  outgoingMessage(position?: number) {
    return this.#run("outgoing message", () => this.#withChat(position, (n, core) => core.newMessage(n, true)))
  }

  unreadUp(position?: number) {
    return this.#run("unread +1", () =>
      this.#withChat(position, (n, core) => core.setUnread(n, (core.chat(n)?.dialog.unreadCount ?? 0) + 1)),
    )
  }

  markRead(position?: number) {
    return this.#run("mark read", () => this.#withChat(position, (n, core) => core.setUnread(n, 0, false)))
  }

  toggleMark(position?: number) {
    return this.#run("toggle unread mark", () =>
      this.#withChat(position, (n, core) => core.setUnread(n, 0, !core.chat(n)?.dialog.unreadMark)),
    )
  }

  draft(position?: number, text = "half a thought, unsent") {
    return this.#run("draft", () => this.#withChat(position, (n, core) => core.setDraft(n, text)))
  }

  clearDraft(position?: number) {
    return this.#run("clear draft", () => this.#withChat(position, (n, core) => core.setDraft(n, "")))
  }

  togglePin(position?: number) {
    return this.#run("toggle pin", () => this.#withChat(position, (n, core) => core.togglePin(n)))
  }

  close(position?: number) {
    return this.#run("close", () => this.#withChat(position, (n, core) => core.setOpen(n, false)))
  }

  rename(position?: number) {
    return this.#run("rename", () => this.#withChat(position, (n, core) => core.rename(n)))
  }

  /**
   * Someone starts (or changes what they are doing) in the chat at
   * `position`: expect 1 row rendered and 0 lists. The same activity again
   * renders nothing; `stopTyping` renders the row once more.
   */
  typing(position?: number, kind: SidebarActivityStatus["kind"] = "typing", text?: string) {
    const words: Record<SidebarActivityStatus["kind"], string> = {
      typing: "Ada is typing",
      working: "Working",
      recording: "Ada is recording voice",
      sending: "Ada is sending photo",
    }
    return this.#run(`activity ${kind}`, () =>
      this.#withChat(position, (n) => this.#typingSignal(String(n) as ChatID).set({ status: { kind, text: text ?? words[kind] } })),
    )
  }

  stopTyping(position?: number) {
    return this.#run("stop typing", () => this.#withChat(position, (n) => this.#typingSignal(String(n) as ChatID).set(undefined)))
  }

  /** The rows' compose activity source: one signal per chat, as the typing feature's index gives. */
  typingFor = (item: SidebarItem) => this.#typingSignal(item.chatId)

  readonly #typing = new Map<ChatID, Signal<SidebarActivity | undefined>>()

  #typingSignal(chatId: ChatID): Signal<SidebarActivity | undefined> {
    let found = this.#typing.get(chatId)
    if (!found) {
      found = signal<SidebarActivity | undefined>(undefined)
      this.#typing.set(chatId, found)
    }
    return found
  }

  /** Reverse the first visible unpinned rows: a pure reorder. Expect 0 rows rendered. */
  reorder(from = 0, span = 8) {
    return this.#run("reorder", () => this.session.peek().core.reorder(from, span))
  }

  open(position?: number, intent: OpenIntent = "here") {
    return this.#run(`open (${intent})`, () => {
      const key = this.model.items.peek()[(position ?? this.position.peek()) - 1]
      if (key) this.model.open(key, intent)
    })
  }

  setMode(mode: SidebarMode) {
    return this.#run(`mode ${mode}`, () => this.model.setMode(mode))
  }

  scale(count: number) {
    this.#count = count
    return this.#run(`scale ${count}`, () => this.session.peek().core.scale(count))
  }

  /** A fresh session: the first-load state shows until the core answers (see latency). */
  restart() {
    return this.#run("restart", () => {
      const previous = this.session.peek()
      this.session.set(this.#createSession())
      // After the new session's first commit, so no old row reads a disposed store.
      requestAnimationFrame(() =>
        setTimeout(() => {
          previous.model.dispose()
          previous.client.dispose()
          previous.scheduler.dispose()
          previous.core.dispose()
        }, 0),
      )
    })
  }

  setLatency(latency: Latency) {
    this.latency.set(latency)
    this.session.peek().core.latency.set(latency)
  }

  setDensity(density: SidebarDensity) {
    return this.#run(`density ${density}`, () => this.density.set(density))
  }

  setUnreadStyle(style: UnreadStyle) {
    return this.#run(`unread style ${style}`, () => this.unreadStyle.set(style))
  }

  setTheme(theme: LabTheme) {
    applyTheme(theme)
    this.theme.set(theme)
    this.#publishState()
  }

  setDir(dir: LabDir) {
    applyDir(dir)
    this.dir.set(dir)
    this.#publishState()
  }

  focusSidebar(): boolean {
    return this.handle.focus()
  }

  /**
   * Scroll the list over `frames` frames: by default from top to bottom (a
   * very fast scroll at 5,000 chats), or `step` pixels per frame from the
   * top (a slow scroll). Measures frame gaps, script per frame, long
   * animation frames, and rows rendered, then waits for lite rows to fill in.
   */
  async scrollTest(frames = 120, step?: number): Promise<ScrollResult> {
    const scroller = document.querySelector<HTMLElement>('[data-lab-stage] [role="listbox"]')?.parentElement
    if (!scroller) throw new Error("no list on screen")
    scroller.scrollTop = 0
    await nextFrame()
    await new Promise((resolve) => setTimeout(resolve, 300))
    this.counter.reset()
    const max = scroller.scrollHeight - scroller.clientHeight
    const perFrame = step ?? max / frames
    let scrollAt: number | undefined
    const onScroll = () => {
      scrollAt ??= performance.now()
    }
    document.addEventListener("scroll", onScroll, { capture: true, passive: true })
    const longFrames: LongFrameEntry[] = []
    const supported = PerformanceObserver.supportedEntryTypes?.includes("long-animation-frame") ?? false
    const observer = supported ? new PerformanceObserver((list) => longFrames.push(...list.getEntries())) : undefined
    observer?.observe({ type: "long-animation-frame" })
    const gaps: number[] = []
    const scripts: number[] = []
    let last = performance.now()
    let maxRows = 0
    let maxRendered = 0
    for (let frame = 1; frame <= frames; frame++) {
      const before = this.counter.count("sidebar:row")
      scrollAt = undefined
      scroller.scrollTop = Math.min(max, perFrame * frame)
      await nextFrame()
      const now = performance.now()
      gaps.push(now - last)
      if (scrollAt !== undefined) scripts.push(now - scrollAt)
      last = now
      maxRows = Math.max(maxRows, this.counter.count("sidebar:row") - before)
      maxRendered = Math.max(maxRendered, scroller.querySelectorAll('[role="option"]:not([hidden])').length)
    }
    const scrolled = this.counter.count("sidebar:row")
    // Let the list settle and fill its lite rows in.
    await new Promise((resolve) => setTimeout(resolve, 400))
    document.removeEventListener("scroll", onScroll, { capture: true })
    observer?.disconnect()
    const result: ScrollResult = {
      frames,
      step: Math.round(perFrame),
      frameMs: stats(gaps),
      scriptMs: stats(scripts),
      longFrames: {
        supported,
        count: longFrames.length,
        maxMs: Math.round(Math.max(0, ...longFrames.map((entry) => entry.duration))),
        scriptMs: Math.round(
          longFrames.reduce((sum, entry) => sum + (entry.scripts ?? []).reduce((s, script) => s + script.duration, 0), 0),
        ),
      },
      rowsRendered: scrolled,
      maxRowsInOneFrame: maxRows,
      fillRows: this.counter.count("sidebar:row") - scrolled,
      maxRenderedAtOnce: maxRendered,
    }
    this.lastScroll.set(result)
    this.#publishState()
    return result
  }

  /** The context menu's actions, wired to the lab core. */
  actions = (item: SidebarItem): readonly SidebarAction[] => {
    const core = this.session.peek().core
    const n = Number(item.chatId)
    return basicActions(item, {
      togglePin: () => void this.#run("menu: pin", () => core.togglePin(n)),
      markRead: () => void this.#run("menu: mark read", () => core.setUnread(n, 0, false)),
      markUnread: () => void this.#run("menu: mark unread", () => core.setUnread(n, 0, true)),
      toggleArchive: () => void this.#run("menu: archive", () => core.toggleArchive(n)),
      close: () => void this.#run("menu: close", () => core.setOpen(n, false)),
      keep: () => void this.#run("menu: keep", () => core.setOpen(n, true)),
      copyLink: () => this.#note(`copy link https://inline.chat/c/${item.chatId}`),
      isTemporary: () => core.chat(n)?.dialog.open === false && !item.pinned,
      isArchived: () => core.chat(n)?.dialog.archived === true,
      setNotifications: (_, mode) => void this.#run(`menu: notifications ${mode}`, () => core.setNotifications(n, mode)),
      setFollow: (_, mode) => void this.#run(`menu: follow ${mode}`, () => core.setFollow(n, mode)),
    })
  }

  onOpened = (event: { key: RowKey; intent: OpenIntent; via: string }) => {
    this.#note(`opened ${event.key} (${event.intent}, ${event.via})`)
  }

  // MARK: Internals

  #createSession(): Session {
    const scheduler = browserScheduler()
    const core = new LabCore(this.#count, (fn) => scheduler.frame(fn))
    core.latency.set(this.latency.peek())
    const client = createStoreClient({ endpoint: core.endpoint, scheduler })
    const workspace = new Workspace({ createId: () => "lab" })
    const model = new SidebarModel({ client, workspace })
    return { core, client, scheduler, workspace, model }
  }

  #withChat(position: number | undefined, fn: (n: number, core: LabCore) => void) {
    const n = this.chatAt(position)
    if (n !== undefined) fn(n, this.session.peek().core)
  }

  #note(line: string) {
    this.log.set([line, ...this.log.peek()].slice(0, 8))
  }

  /** Run one operation at a time and measure what it rendered. */
  #run(name: string, fn: () => void): Promise<OperationResult> {
    const run = this.#busy.then(async () => {
      this.counter.reset()
      const start = performance.now()
      fn()
      await nextFrame()
      await nextTask()
      const result: OperationResult = {
        name,
        rows: this.counter.count("sidebar:row"),
        lists: this.counter.count("sidebar:list"),
        total: this.counter.total(),
        ms: Math.round((performance.now() - start) * 10) / 10,
      }
      this.lastOp.set(result)
      return result
    })
    this.#busy = run.catch(() => undefined)
    return run
  }

  #publishTimer: ReturnType<typeof setTimeout> | undefined

  #schedulePublish() {
    if (this.#publishTimer !== undefined) clearTimeout(this.#publishTimer)
    this.#publishTimer = setTimeout(() => {
      this.#publishTimer = undefined
      this.#publishState()
    }, 0)
  }

  #publishState() {
    const session = this.session.peek()
    const model = session.model
    ;(globalThis as { __sidebarLab?: unknown }).__sidebarLab = {
      count: session.core.count.peek(),
      listed: model.items.peek().length,
      mode: model.mode.peek(),
      ready: session.core.ready.peek(),
      latency: this.latency.peek(),
      density: this.density.peek(),
      unreadStyle: this.unreadStyle.peek(),
      theme: this.theme.peek(),
      dir: this.dir.peek(),
      position: this.position.peek(),
      selectedChatId: model.selectedChatId.peek(),
      lastOp: this.lastOp.peek(),
      lastScroll: this.lastScroll.peek(),
      list: this.handle.snapshot(),
      /** Chats with compose activity, and what each row says. */
      activity: [...this.#typing.entries()].flatMap(([chatId, value]) => {
        const status = value.peek()?.status
        return status ? [{ chatId, kind: status.kind, text: status.text }] : []
      }),
      /** The open context menu's entries, by accessible name (`aria-label`) and `aria-keyshortcuts`. */
      menu: openMenuEntries(),
      log: this.log.peek(),
    }
  }

  /** Plain functions for a driver (the coordinator's browser session). */
  control() {
    return {
      newMessage: (position?: number) => this.newMessage(position),
      outgoingMessage: (position?: number) => this.outgoingMessage(position),
      unreadUp: (position?: number) => this.unreadUp(position),
      markRead: (position?: number) => this.markRead(position),
      toggleMark: (position?: number) => this.toggleMark(position),
      draft: (position?: number, text?: string) => this.draft(position, text),
      clearDraft: (position?: number) => this.clearDraft(position),
      togglePin: (position?: number) => this.togglePin(position),
      close: (position?: number) => this.close(position),
      rename: (position?: number) => this.rename(position),
      typing: (position?: number, kind?: SidebarActivityStatus["kind"], text?: string) => this.typing(position, kind, text),
      stopTyping: (position?: number) => this.stopTyping(position),
      reorder: (from?: number, span?: number) => this.reorder(from, span),
      open: (position?: number, intent?: OpenIntent) => this.open(position, intent),
      setMode: (mode: SidebarMode) => this.setMode(mode),
      scale: (count: number) => this.scale(count),
      restart: () => this.restart(),
      setLatency: (latency: Latency) => this.setLatency(latency),
      setDensity: (density: SidebarDensity) => this.setDensity(density),
      setUnreadStyle: (style: UnreadStyle) => this.setUnreadStyle(style),
      setTheme: (theme: LabTheme) => this.setTheme(theme),
      setDir: (dir: LabDir) => this.setDir(dir),
      setPosition: (position: number) => this.position.set(position),
      focusSidebar: () => this.focusSidebar(),
      /** `scrollTest()` is a top-to-bottom fling; `scrollTest(120, 20)` a slow scroll of 20 px a frame. */
      scrollTest: (frames?: number, step?: number) => this.scrollTest(frames, step),
      /** Fresh plain state (also on `__sidebarLab`, refreshed after each operation). */
      state: () => {
        this.#publishState()
        return (globalThis as { __sidebarLab?: unknown }).__sidebarLab
      },
    }
  }
}
