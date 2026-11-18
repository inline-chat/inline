/**
 * Binds a workspace to a session history (the address bar), both ways.
 *
 * ## Back and Forward policy
 *
 * The address bar shows the focused pane's destination. Every browser history
 * entry the app creates is stamped with the pane and pane-history entry it
 * shows. Browser Back and Forward replay those entries:
 *
 * 1. Navigating the focused pane (`open` here, or in another pane that takes
 *    focus) pushes one browser entry. `replace` replaces it. Navigating a pane
 *    that does not take focus does not touch browser history.
 * 2. Focusing another pane, or closing one, replaces the current browser entry
 *    so the URL shows the newly focused pane. It adds no entry.
 * 3. Browser Back or Forward onto a stamped entry moves that entry's pane to
 *    that entry and focuses the pane. With one pane, browser Back and Forward
 *    are exactly the pane's Back and Forward. With two, they walk the user's
 *    visits in order and focus follows, so the pane that moves is always the
 *    focused one.
 * 4. A stamped entry whose pane was closed, or whose pane entry fell off the
 *    history cap, opens its URL in that pane if it is still there, otherwise
 *    in the focused pane.
 * 5. An entry the app did not stamp (first load, a typed URL, a link from
 *    elsewhere) opens its URL in the focused pane and is stamped in place. The
 *    root path `/` and malformed paths keep the restored workspace and show
 *    its URL instead.
 * 6. The in-app Back and Forward commands act on the focused pane only. When
 *    the neighboring browser entry is that pane's neighboring entry, they move
 *    the browser (`history.go`) so the two stay in step; otherwise they move
 *    the pane and replace the current browser entry.
 *
 * The app never adds entries the user did not cause (no guard entries), so
 * browser Back leaves the app only from the first entry of the app's own
 * session history, which is what a user expects. Browsers also skip entries
 * pushed without a user gesture, which rules out guard tricks anyway.
 */

import type { Destination } from "./destination"
import type { HistoryAdapter, HistoryLocation } from "./history"
import { decodeAppPath, encodeDestination, sameDestination } from "./url"
import type { EntryId, PaneId, Workspace, WorkspaceChange } from "./workspace"

/** What the app stores in `history.state`. */
export type HistoryStamp = {
  /** Workspace ID. */
  readonly ws: string
  readonly pane: PaneId
  readonly entry: EntryId
  /** Increases with every entry this app creates; orders entries. */
  readonly seq: number
}

export type HistoryState = { readonly inline: HistoryStamp }

export const readStamp = (state: unknown): HistoryStamp | undefined => {
  if (typeof state !== "object" || state === null) return undefined
  const stamp = (state as { inline?: unknown }).inline
  if (typeof stamp !== "object" || stamp === null) return undefined
  const { ws, pane, entry, seq } = stamp as Record<string, unknown>
  if (typeof ws !== "string" || typeof pane !== "string" || typeof entry !== "string" || typeof seq !== "number") {
    return undefined
  }
  return { ws, pane, entry, seq }
}

export type HistoryBinding = {
  /** The in-app Back command for the focused pane (policy rule 6). */
  back(): boolean
  /** The in-app Forward command for the focused pane (policy rule 6). */
  forward(): boolean
  dispose(): void
}

export type HistoryBindingOptions = {
  /** Clock for entry sequence numbers. Defaults to `Date.now`. */
  readonly now?: () => number
}

export const bindWorkspaceToHistory = (
  workspace: Workspace,
  history: HistoryAdapter,
  options: HistoryBindingOptions = {},
): HistoryBinding => {
  const now = options.now ?? Date.now
  let lastSeq = 0
  let applying = false
  /** Stamps of the entries this binding knows about, by sequence number. */
  const known = new Map<number, HistoryStamp>()
  let currentSeq: number | undefined

  const nextSeq = (): number => {
    lastSeq = Math.max(now(), lastSeq + 1)
    return lastSeq
  }

  const stampFor = (paneId: PaneId, seq: number): HistoryStamp | undefined => {
    const entry = workspace.currentEntry(paneId)
    if (!entry) return undefined
    return { ws: workspace.state.peek().id, pane: paneId, entry: entry.id, seq }
  }

  const write = (mode: "push" | "replace") => {
    const paneId = workspace.focusedPaneId.peek()
    const destination = workspace.destination(paneId)
    // Replacing keeps the entry's place in the order; pushing makes a new one.
    const seq = mode === "replace" && currentSeq !== undefined ? currentSeq : nextSeq()
    const stamp = stampFor(paneId, seq)
    if (!destination || !stamp) return
    const state: HistoryState = { inline: stamp }
    const path = encodeDestination(destination)
    if (mode === "push") {
      if (currentSeq !== undefined) {
        for (const key of Array.from(known.keys())) if (key > currentSeq) known.delete(key)
      }
      history.push(path, state)
    } else {
      history.replace(path, state)
    }
    known.set(seq, stamp)
    currentSeq = seq
  }

  const onChange = (change: WorkspaceChange) => {
    if (applying) return
    const focused = workspace.focusedPaneId.peek()
    switch (change.kind) {
      case "push":
        if (change.paneId === focused) write("push")
        break
      case "replace":
      case "move":
        if (change.paneId === focused) write("replace")
        break
      case "focus":
      case "layout":
        write("replace")
        break
    }
  }

  const apply = (fn: () => void) => {
    applying = true
    try {
      fn()
    } finally {
      applying = false
    }
  }

  const decode = (path: string): Destination | undefined => {
    const result = decodeAppPath(path)
    if (!result.ok || result.destination.kind === "empty") return undefined
    return result.destination
  }

  /** Make the workspace show `location`; then make sure the entry carries a valid stamp. */
  const arrive = (location: HistoryLocation) => {
    const stamp = readStamp(location.state)
    const workspaceId = workspace.state.peek().id
    if (stamp && stamp.ws === workspaceId) {
      lastSeq = Math.max(lastSeq, stamp.seq)
      const pane = workspace.pane(stamp.pane)
      if (pane && pane.entries.some((entry) => entry.id === stamp.entry)) {
        apply(() => {
          workspace.goToEntry(stamp.pane, stamp.entry, { focus: true })
        })
        known.set(stamp.seq, stamp)
        currentSeq = stamp.seq
        return
      }
      // Rule 4: the pane or its entry is gone; reopen the URL.
      const destination = decode(location.path)
      currentSeq = stamp.seq
      if (destination) {
        apply(() => {
          if (pane) workspace.openInPane(pane.id, destination, { focus: true })
          else workspace.open(destination)
        })
      }
      write("replace")
      return
    }
    // Rule 5: an entry the app did not make.
    currentSeq = undefined
    const destination = decode(location.path)
    if (destination && !sameDestination(destination, workspace.focusedDestination.peek())) {
      apply(() => {
        workspace.open(destination)
      })
    }
    write("replace")
  }

  const stepTo = (direction: -1 | 1): boolean => {
    const paneId = workspace.focusedPaneId.peek()
    const pane = workspace.pane(paneId)
    if (!pane) return false
    const target = pane.entries[pane.index + direction]
    if (!target) return false
    if (currentSeq !== undefined) {
      const seqs = [...known.keys()].filter((seq) => (direction < 0 ? seq < currentSeq! : seq > currentSeq!))
      const neighbor = seqs.length > 0 ? known.get(direction < 0 ? Math.max(...seqs) : Math.min(...seqs)) : undefined
      if (neighbor && neighbor.pane === paneId && neighbor.entry === target.id) {
        history.go(direction)
        return true
      }
    }
    return direction < 0 ? workspace.back(paneId) : workspace.forward(paneId)
  }

  const unsubscribeWorkspace = workspace.subscribe(onChange)
  const unlisten = history.listen(arrive)
  arrive(history.current())

  return {
    back: () => stepTo(-1),
    forward: () => stepTo(1),
    dispose: () => {
      unsubscribeWorkspace()
      unlisten()
    },
  }
}
