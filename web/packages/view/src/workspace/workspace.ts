/**
 * The workspace model: panes, each with its own back and forward history, the
 * focused pane, and open intents. Framework-free; views read its signals and
 * call its methods. The browser address bar is bound to it separately
 * (`browser-sync.ts`), so the same model drives a browser tab, an Electron
 * window or a test.
 *
 * One pane is the normal case. A second pane (a reply thread beside its
 * chat, a chat opened "in the other pane") is more data in `panes`, not a
 * different code path.
 */

import { batch, computed, signal, type ReadSignal } from "@inline/reactive"
import { emptyDestination, type Destination } from "./destination"
import { sameDestination } from "./url"
import { ViewStateStore } from "./view-state"

export type PaneId = string
export type EntryId = string

export type HistoryEntry = {
  readonly id: EntryId
  readonly destination: Destination
}

export type PaneState = {
  readonly id: PaneId
  /** Oldest first. Never empty. */
  readonly entries: readonly HistoryEntry[]
  /** The entry shown now. */
  readonly index: number
}

export type WorkspaceState = {
  /** Identity of this workspace; browser history entries are stamped with it. */
  readonly id: string
  /** Left to right. Never empty. */
  readonly panes: readonly PaneState[]
  readonly focusedPaneId: PaneId
  /** Counter for pane and entry IDs. */
  readonly nextId: number
}

/**
 * How to open a destination. "Where" is the destination; this is "how".
 *
 * - `here`: in the focused pane, pushing onto its history.
 * - `otherPane`: in the pane beside the focused one, creating it if there is
 *   only one pane.
 * - `newPane`: in a new pane right of the focused one. At the pane limit it
 *   behaves like `otherPane`.
 * - `newTab`, `newWindow`: handed to the injected opener. Without an opener
 *   they behave like `here`.
 */
export type OpenIntent = "here" | "otherPane" | "newPane" | "newTab" | "newWindow"

export type OpenOptions = {
  readonly intent?: OpenIntent
  /** Move focus to the pane that opened the destination. Defaults to true. */
  readonly focus?: boolean
}

export type OpenResult =
  | { readonly kind: "pane"; readonly paneId: PaneId; readonly entryId: EntryId; readonly changed: boolean }
  | { readonly kind: "delegated"; readonly intent: "newTab" | "newWindow" }

/** Opens a destination outside this workspace: a browser tab or an app window. */
export type ExternalOpener = (destination: Destination, target: "newTab" | "newWindow") => void

/**
 * What changed, for observers that must mirror the model (the address bar).
 * Emitted after the state signal is updated.
 *
 * - `push`: a new entry became current in `paneId` (including a new pane's first).
 * - `replace`: the current entry of `paneId` was replaced.
 * - `move`: `paneId` moved within its history (back, forward, history menu).
 * - `focus`: the focused pane changed.
 * - `layout`: a pane was closed; `paneId` is the focused pane afterwards.
 */
export type WorkspaceChange = {
  readonly kind: "push" | "replace" | "move" | "focus" | "layout"
  readonly paneId: PaneId
}

export type WorkspaceOptions = {
  /** The destination of the first pane when there is no restored state. */
  readonly initial?: Destination
  /** A restored state, from `restoreWorkspace`. */
  readonly state?: WorkspaceState
  /** Maximum entries kept per pane; older entries are dropped. Default 50. */
  readonly historyLimit?: number
  /** Maximum number of panes. Default 3. */
  readonly maxPanes?: number
  readonly opener?: ExternalOpener
  /** Creates the workspace ID. Defaults to a random string. */
  readonly createId?: () => string
  /** Entries kept in the view-state bag. Default 200. */
  readonly viewStateLimit?: number
}

export const defaultHistoryLimit = 50
export const defaultMaxPanes = 3

const randomId = (): string => Math.random().toString(36).slice(2, 10) + Date.now().toString(36)

const currentEntry = (pane: PaneState): HistoryEntry => {
  const entry = pane.entries[pane.index] ?? pane.entries[pane.entries.length - 1]
  // A pane is never empty; this fallback only satisfies the type checker.
  return entry ?? { id: "e0", destination: emptyDestination }
}

export const initialWorkspaceState = (id: string, initial: Destination = emptyDestination): WorkspaceState => ({
  id,
  panes: [{ id: "p1", entries: [{ id: "e2", destination: initial }], index: 0 }],
  focusedPaneId: "p1",
  nextId: 3,
})

export class Workspace {
  readonly historyLimit: number
  readonly maxPanes: number
  /** Per-destination view state (scroll place and similar). Survives navigation. */
  readonly viewState: ViewStateStore

  readonly #state
  readonly #opener: ExternalOpener | undefined
  readonly #listeners = new Set<(change: WorkspaceChange) => void>()

  /** The whole model as one immutable value. */
  readonly state: ReadSignal<WorkspaceState>
  readonly panes: ReadSignal<readonly PaneState[]>
  readonly focusedPaneId: ReadSignal<PaneId>
  readonly focusedPane: ReadSignal<PaneState>
  /** What the focused pane shows. The address bar mirrors this. */
  readonly focusedDestination: ReadSignal<Destination>
  readonly canGoBack: ReadSignal<boolean>
  readonly canGoForward: ReadSignal<boolean>
  readonly canClosePane: ReadSignal<boolean>

  constructor(options: WorkspaceOptions = {}) {
    this.historyLimit = Math.max(1, options.historyLimit ?? defaultHistoryLimit)
    this.maxPanes = Math.max(1, options.maxPanes ?? defaultMaxPanes)
    this.#opener = options.opener
    this.viewState = new ViewStateStore(options.viewStateLimit)
    const initial =
      options.state ?? initialWorkspaceState((options.createId ?? randomId)(), options.initial ?? emptyDestination)
    this.#state = signal<WorkspaceState>(initial)
    this.state = { get: () => this.#state.get(), peek: () => this.#state.peek() }
    this.panes = computed(() => this.#state.get().panes)
    this.focusedPaneId = computed(() => this.#state.get().focusedPaneId)
    this.focusedPane = computed(() => {
      const state = this.#state.get()
      return state.panes.find((pane) => pane.id === state.focusedPaneId) ?? (state.panes[0] as PaneState)
    })
    this.focusedDestination = computed(() => currentEntry(this.focusedPane.get()).destination, {
      equals: sameDestination,
    })
    this.canGoBack = computed(() => this.focusedPane.get().index > 0)
    this.canGoForward = computed(() => {
      const pane = this.focusedPane.get()
      return pane.index < pane.entries.length - 1
    })
    this.canClosePane = computed(() => this.#state.get().panes.length > 1)
  }

  // MARK: - Reading

  pane(paneId: PaneId): PaneState | undefined {
    return this.#state.peek().panes.find((pane) => pane.id === paneId)
  }

  /** The destination a pane shows now. */
  destination(paneId: PaneId = this.#state.peek().focusedPaneId): Destination | undefined {
    const pane = this.pane(paneId)
    return pane ? currentEntry(pane).destination : undefined
  }

  currentEntry(paneId: PaneId = this.#state.peek().focusedPaneId): HistoryEntry | undefined {
    const pane = this.pane(paneId)
    return pane ? currentEntry(pane) : undefined
  }

  /** Entries behind the current one, nearest first; for a history menu (the Mac app shows 10). */
  backEntries(paneId: PaneId = this.#state.peek().focusedPaneId, limit = 10): readonly HistoryEntry[] {
    const pane = this.pane(paneId)
    if (!pane) return []
    return pane.entries.slice(Math.max(0, pane.index - limit), pane.index).reverse()
  }

  /** Entries ahead of the current one, nearest first. */
  forwardEntries(paneId: PaneId = this.#state.peek().focusedPaneId, limit = 10): readonly HistoryEntry[] {
    const pane = this.pane(paneId)
    if (!pane) return []
    return pane.entries.slice(pane.index + 1, pane.index + 1 + limit)
  }

  /** Listen for changes, in order. Returns an unsubscribe function. */
  subscribe(listener: (change: WorkspaceChange) => void): () => void {
    this.#listeners.add(listener)
    return () => {
      this.#listeners.delete(listener)
    }
  }

  // MARK: - Navigating

  open(destination: Destination, options: OpenOptions = {}): OpenResult {
    const intent = options.intent ?? "here"
    const focus = options.focus ?? true
    if (intent === "newTab" || intent === "newWindow") {
      if (this.#opener) {
        this.#opener(destination, intent)
        return { kind: "delegated", intent }
      }
      return this.#openInPane(this.#state.peek().focusedPaneId, destination, focus)
    }
    if (intent === "here") return this.#openInPane(this.#state.peek().focusedPaneId, destination, focus)

    const state = this.#state.peek()
    const focusedIndex = state.panes.findIndex((pane) => pane.id === state.focusedPaneId)
    const canAdd = state.panes.length < this.maxPanes
    if (intent === "newPane" && canAdd) return this.#addPane(focusedIndex + 1, destination, focus)

    // otherPane, or newPane at the limit.
    const other = state.panes[focusedIndex + 1] ?? state.panes[focusedIndex - 1]
    if (other) return this.#openInPane(other.id, destination, focus)
    if (canAdd) return this.#addPane(focusedIndex + 1, destination, focus)
    return this.#openInPane(state.focusedPaneId, destination, focus)
  }

  /** Open in a specific pane, pushing onto its history. */
  openInPane(paneId: PaneId, destination: Destination, options: { focus?: boolean } = {}): OpenResult | undefined {
    if (!this.pane(paneId)) return undefined
    return this.#openInPane(paneId, destination, options.focus ?? true)
  }

  /** Replace the current entry of a pane without adding history (a redirect, a canonical form). */
  replace(destination: Destination, paneId: PaneId = this.#state.peek().focusedPaneId): boolean {
    const pane = this.pane(paneId)
    if (!pane) return false
    const entry = currentEntry(pane)
    if (sameDestination(entry.destination, destination)) return false
    batch(() => {
      const id = this.#takeId("e")
      this.#updatePane(paneId, (p) => ({
        ...p,
        entries: p.entries.map((e, i) => (i === p.index ? { id, destination } : e)),
      }))
    })
    this.#emit({ kind: "replace", paneId })
    return true
  }

  back(paneId: PaneId = this.#state.peek().focusedPaneId): boolean {
    const pane = this.pane(paneId)
    if (!pane || pane.index <= 0) return false
    return this.#moveTo(paneId, pane.index - 1)
  }

  forward(paneId: PaneId = this.#state.peek().focusedPaneId): boolean {
    const pane = this.pane(paneId)
    if (!pane || pane.index >= pane.entries.length - 1) return false
    return this.#moveTo(paneId, pane.index + 1)
  }

  /** Move a pane to one of its entries (a history menu item, a browser Back). */
  goToEntry(paneId: PaneId, entryId: EntryId, options: { focus?: boolean } = {}): boolean {
    const pane = this.pane(paneId)
    if (!pane) return false
    const index = pane.entries.findIndex((entry) => entry.id === entryId)
    if (index < 0) return false
    if (options.focus) this.focus(paneId)
    if (index === pane.index) return false
    return this.#moveTo(paneId, index)
  }

  focus(paneId: PaneId): boolean {
    const state = this.#state.peek()
    if (state.focusedPaneId === paneId || !this.pane(paneId)) return false
    this.#state.set({ ...state, focusedPaneId: paneId })
    this.#emit({ kind: "focus", paneId })
    return true
  }

  /** Focus the pane `delta` steps to the right (negative: left), clamped. */
  focusAdjacent(delta: number): boolean {
    const state = this.#state.peek()
    const index = state.panes.findIndex((pane) => pane.id === state.focusedPaneId)
    const target = state.panes[Math.min(state.panes.length - 1, Math.max(0, index + delta))]
    return target ? this.focus(target.id) : false
  }

  /** Close a pane. The last pane cannot be closed. Focus moves to a neighbor. */
  closePane(paneId: PaneId = this.#state.peek().focusedPaneId): boolean {
    const state = this.#state.peek()
    if (state.panes.length <= 1) return false
    const index = state.panes.findIndex((pane) => pane.id === paneId)
    if (index < 0) return false
    const panes = state.panes.filter((pane) => pane.id !== paneId)
    const focusedPaneId =
      state.focusedPaneId === paneId ? (panes[Math.max(0, index - 1)] ?? panes[0])?.id ?? state.focusedPaneId : state.focusedPaneId
    this.#state.set({ ...state, panes, focusedPaneId })
    this.#emit({ kind: "layout", paneId: focusedPaneId })
    return true
  }

  // MARK: - Internals

  #takeId(prefix: "p" | "e"): string {
    const state = this.#state.peek()
    this.#state.set({ ...state, nextId: state.nextId + 1 })
    return `${prefix}${state.nextId}`
  }

  #updatePane(paneId: PaneId, fn: (pane: PaneState) => PaneState, focusedPaneId?: PaneId): void {
    const state = this.#state.peek()
    this.#state.set({
      ...state,
      panes: state.panes.map((pane) => (pane.id === paneId ? fn(pane) : pane)),
      focusedPaneId: focusedPaneId ?? state.focusedPaneId,
    })
  }

  #openInPane(paneId: PaneId, destination: Destination, focus: boolean): OpenResult {
    const pane = this.pane(paneId)
    if (!pane) throw new Error(`Unknown pane ${paneId}`)
    const focusChanged = focus && this.#state.peek().focusedPaneId !== paneId
    const entry = currentEntry(pane)
    if (sameDestination(entry.destination, destination)) {
      if (focusChanged) this.focus(paneId)
      return { kind: "pane", paneId, entryId: entry.id, changed: false }
    }
    const id = batch(() => {
      const id = this.#takeId("e")
      const next: HistoryEntry = { id, destination }
      this.#updatePane(
        paneId,
        (p) => {
          const kept = [...p.entries.slice(0, p.index + 1), next]
          const entries = kept.length > this.historyLimit ? kept.slice(kept.length - this.historyLimit) : kept
          return { ...p, entries, index: entries.length - 1 }
        },
        focus ? paneId : undefined,
      )
      return id
    })
    // One change even when focus moved too: the push lands in the now-focused pane.
    this.#emit({ kind: "push", paneId })
    return { kind: "pane", paneId, entryId: id, changed: true }
  }

  #addPane(at: number, destination: Destination, focus: boolean): OpenResult {
    const state = this.#state.peek()
    const paneId = `p${state.nextId}`
    const entryId = `e${state.nextId + 1}`
    const pane: PaneState = { id: paneId, entries: [{ id: entryId, destination }], index: 0 }
    const panes = [...state.panes.slice(0, at), pane, ...state.panes.slice(at)]
    this.#state.set({
      ...state,
      panes,
      focusedPaneId: focus ? paneId : state.focusedPaneId,
      nextId: state.nextId + 2,
    })
    // A new pane's first entry is a navigation like any other.
    this.#emit({ kind: "push", paneId })
    return { kind: "pane", paneId, entryId, changed: true }
  }

  #moveTo(paneId: PaneId, index: number): boolean {
    this.#updatePane(paneId, (p) => ({ ...p, index }))
    this.#emit({ kind: "move", paneId })
    return true
  }

  #emit(change: WorkspaceChange): void {
    for (const listener of Array.from(this.#listeners)) listener(change)
  }
}

