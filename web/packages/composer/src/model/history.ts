import type { ComposerEntity, DocState, Selection } from "./types"

/**
 * Undo and redo, owned by us because programmatic DOM edits break the
 * browser's own history.
 *
 * A step is the content and selection before an edit. Consecutive edits of
 * the same coalescing kind ("typing" or "deleting") become one step while
 * they continue where the last one left off and arrive within `pauseMs` of
 * each other. A selection move, a pause, a different kind or any structural
 * edit starts a new step. Undo restores a step's selection with its content.
 *
 * Immutable like the document: every function returns a new history.
 */

/** How an edit joins the history. */
export type EditKind =
  /** Inserting text at a caret. Coalesces with more typing. */
  | "typing"
  /** Deleting a character or word at a caret. Coalesces with more deleting. */
  | "deleting"
  /** Anything else: Enter, paste, formatting, atoms, cut, drop. Always its own step. */
  | "structural"

export type HistoryEntry = {
  readonly text: string
  readonly entities: readonly ComposerEntity[]
  readonly selection: Selection
}

export type History = {
  readonly undo: readonly HistoryEntry[]
  readonly redo: readonly HistoryEntry[]
  /** Kind of the last recorded edit, `null` after a boundary. */
  readonly lastKind: EditKind | null
  /** Clock time of the last recorded edit. */
  readonly lastTime: number
  /** Caret after the last recorded edit; typing that continues from it coalesces. */
  readonly lastCaret: number
}

export type HistoryOptions = {
  /** Most steps kept; the oldest are dropped. Start: 200. */
  limit?: number
  /** A pause longer than this starts a new step. Start: 1000 ms. */
  pauseMs?: number
}

export const HISTORY_LIMIT = 200
export const HISTORY_PAUSE_MS = 1000

export const emptyHistory = (): History => ({
  undo: [],
  redo: [],
  lastKind: null,
  lastTime: 0,
  lastCaret: -1,
})

const entryOf = (state: DocState): HistoryEntry => ({
  text: state.text,
  entities: state.entities,
  selection: state.selection,
})

const contentChanged = (a: DocState, b: DocState) => a.text !== b.text || a.entities !== b.entities

/**
 * Record the edit from `before` to `after`. A change of selection alone is
 * not an edit; record it with `markBoundary` instead.
 */
export const record = (
  history: History,
  before: DocState,
  after: DocState,
  kind: EditKind,
  now: number,
  options: HistoryOptions = {},
): History => {
  if (!contentChanged(before, after)) return history
  const pauseMs = options.pauseMs ?? HISTORY_PAUSE_MS
  const limit = Math.max(1, options.limit ?? HISTORY_LIMIT)
  const caretBefore = before.selection.anchor === before.selection.focus ? before.selection.focus : -2
  const coalesce =
    kind !== "structural" &&
    history.lastKind === kind &&
    now - history.lastTime <= pauseMs &&
    caretBefore === history.lastCaret &&
    history.undo.length > 0
  const caretAfter = after.selection.anchor === after.selection.focus ? after.selection.focus : -2
  if (coalesce) {
    return { ...history, redo: [], lastTime: now, lastCaret: caretAfter }
  }
  const undo = [...history.undo, entryOf(before)]
  if (undo.length > limit) undo.splice(0, undo.length - limit)
  return {
    undo,
    redo: [],
    lastKind: kind === "structural" ? null : kind,
    lastTime: now,
    lastCaret: caretAfter,
  }
}

/** End coalescing: the next edit starts a new step (a selection move, a blur). */
export const markBoundary = (history: History): History =>
  history.lastKind === null ? history : { ...history, lastKind: null, lastCaret: -1 }

export const canUndo = (history: History): boolean => history.undo.length > 0
export const canRedo = (history: History): boolean => history.redo.length > 0

const restore = (state: DocState, entry: HistoryEntry): DocState => ({
  text: entry.text,
  entities: entry.entities,
  selection: entry.selection,
  pendingMarks: null,
  // The revision only moves forward, so a draft saved after an undo is newer.
  revision: state.revision + 1,
})

/** Undo one step. Returns `null` when there is nothing to undo. */
export const undo = (
  history: History,
  state: DocState,
): { history: History; state: DocState } | null => {
  const entry = history.undo[history.undo.length - 1]
  if (!entry) return null
  return {
    history: {
      undo: history.undo.slice(0, -1),
      redo: [...history.redo, entryOf(state)],
      lastKind: null,
      lastTime: history.lastTime,
      lastCaret: -1,
    },
    state: restore(state, entry),
  }
}

/** Redo one step. Returns `null` when there is nothing to redo. */
export const redo = (
  history: History,
  state: DocState,
): { history: History; state: DocState } | null => {
  const entry = history.redo[history.redo.length - 1]
  if (!entry) return null
  return {
    history: {
      undo: [...history.undo, entryOf(state)],
      redo: history.redo.slice(0, -1),
      lastKind: null,
      lastTime: history.lastTime,
      lastCaret: -1,
    },
    state: restore(state, entry),
  }
}
