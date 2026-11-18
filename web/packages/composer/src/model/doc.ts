import {
  atomContaining,
  clamp,
  entitiesEqual,
  entityMarkKey,
  markEntity,
  markKey,
  markOf,
  normalizeEntities,
  snapSurrogate,
  uniqueMarks,
} from "./entities"
import { normalizeText } from "./text"
import {
  entityKind,
  type ComposerEntity,
  type DocState,
  type Mark,
  type Range,
  type Selection,
} from "./types"

// ---------------------------------------------------------------------------
// Construction

export type DocInit = {
  text?: string
  entities?: readonly ComposerEntity[]
  selection?: Selection
  revision?: number
}

/**
 * A document from outside text (a draft, a message being edited). The text
 * goes through `normalizeText` (line endings, non-breaking spaces, control
 * characters) with its entities mapped along, then entities are normalized.
 * The caret goes to the end unless a selection is given.
 */
export const createDoc = (init: DocInit = {}): DocState => {
  const clean = normalizeText(init.text ?? "", init.entities ?? [])
  const text = clean.text
  const entities = normalizeEntities(text, clean.entities)
  const end = text.length
  const selection = normalizeSelection(text, entities, init.selection ?? { anchor: end, focus: end })
  return { text, entities, selection, pendingMarks: null, revision: init.revision ?? 0 }
}

export const emptyDoc = (revision = 0): DocState => createDoc({ revision })

// ---------------------------------------------------------------------------
// Selection

export const selectionRange = (selection: Selection): Range =>
  selection.anchor <= selection.focus
    ? { from: selection.anchor, to: selection.focus }
    : { from: selection.focus, to: selection.anchor }

export const isCollapsed = (selection: Selection): boolean => selection.anchor === selection.focus

export const collapsed = (offset: number): Selection => ({ anchor: offset, focus: offset })

/**
 * Clamp to the text, step off the middle of surrogate pairs and out of
 * atoms. A collapsed caret inside an atom goes to the nearer edge (the end on
 * a tie); a range grows to cover any atom an endpoint falls in.
 */
/** An integer offset within `[0, length]`; anything not finite becomes `length`. */
export const toOffset = (n: number, length: number): number =>
  Number.isFinite(n) ? clamp(Math.trunc(n), 0, length) : length

export const normalizeSelection = (
  text: string,
  entities: readonly ComposerEntity[],
  selection: Selection,
): Selection => {
  let anchor = toOffset(selection.anchor, text.length)
  let focus = toOffset(selection.focus, text.length)
  if (anchor === focus) {
    let caret = snapSurrogate(text, anchor, "back")
    const atom = atomContaining(entities, caret)
    if (atom) {
      const end = atom.offset + atom.length
      caret = caret - atom.offset < end - caret ? atom.offset : end
    }
    return { anchor: caret, focus: caret }
  }
  const backward = anchor > focus
  let from = backward ? focus : anchor
  let to = backward ? anchor : focus
  from = snapSurrogate(text, from, "back")
  to = snapSurrogate(text, to, "forward")
  const atFrom = atomContaining(entities, from)
  if (atFrom) from = atFrom.offset
  const atTo = atomContaining(entities, to)
  if (atTo) to = atTo.offset + atTo.length
  anchor = backward ? to : from
  focus = backward ? from : to
  return { anchor, focus }
}

const sameSelection = (a: Selection, b: Selection) => a.anchor === b.anchor && a.focus === b.focus

/** Move the selection. Clears pending marks when the selection actually moves. */
export const setSelection = (state: DocState, selection: Selection): DocState => {
  const next = normalizeSelection(state.text, state.entities, selection)
  if (sameSelection(next, state.selection)) return state
  return { ...state, selection: next, pendingMarks: null }
}

// ---------------------------------------------------------------------------
// Ranges

/** Step a range off surrogate halves and grow it to whole atoms. */
export const expandRange = (state: Pick<DocState, "text" | "entities">, range: Range): Range => {
  const { text, entities } = state
  const a = toOffset(range.from, text.length)
  const b = toOffset(range.to, text.length)
  let from = Math.min(a, b)
  let to = Math.max(a, b)
  from = snapSurrogate(text, from, "back")
  to = snapSurrogate(text, to, "forward")
  if (from === to) {
    // An insertion point inside an atom moves to its end.
    const atom = atomContaining(entities, from)
    if (atom) from = to = atom.offset + atom.length
    return { from, to }
  }
  for (const e of entities) {
    if (entityKind(e.type) !== "atom") continue
    const end = e.offset + e.length
    if (from < end && to > e.offset) {
      if (e.offset < from) from = e.offset
      if (end > to) to = end
    }
  }
  return { from, to }
}

/**
 * The marks text inserted over `range` gets:
 * - at a collapsed caret with pending marks: the pending marks;
 * - at a collapsed caret: marks that strictly contain it (so typing at the
 *   trailing or leading edge of a mark does not extend it);
 * - over a range: the marks on its first character.
 */
export const activeMarks = (state: DocState, range: Range): Mark[] => {
  const { from, to } = range
  if (from === to && state.pendingMarks && isCollapsed(state.selection) && state.selection.focus === from) {
    return uniqueMarks(state.pendingMarks)
  }
  const marks: Mark[] = []
  for (const e of state.entities) {
    if (entityKind(e.type) !== "mark") continue
    const end = e.offset + e.length
    const covers = from === to ? e.offset < from && from < end : e.offset <= from && from < end
    if (covers) marks.push(markOf(e))
  }
  return uniqueMarks(marks)
}

// ---------------------------------------------------------------------------
// The one edit primitive

export type Insertion = {
  text: string
  /** Entities of the inserted text, with offsets relative to its start. */
  entities?: readonly ComposerEntity[]
  /** Marks applied over the whole inserted text. */
  marks?: readonly Mark[]
}

/**
 * Replace `[from, to)` with `insertion`, keeping every entity correct:
 *
 * - entities wholly before `from` (including ones ending exactly at it) and
 *   wholly after `to` are kept and shifted;
 * - an atom or a derived entity whose inside the edit touches is dropped;
 * - a mark overlapping the edit keeps its parts outside it; if the mark is
 *   among `insertion.marks` it also covers the inserted text (growing),
 *   otherwise it is split around it;
 * - `insertion.marks` cover the inserted text, and equal marks that touch are
 *   merged by normalization.
 *
 * The range is used as given; callers expand it with `expandRange` first so
 * an atom is never cut. Does not touch the selection or the revision.
 */
export const replaceEntities = (
  state: Pick<DocState, "text" | "entities">,
  from: number,
  to: number,
  insertion: Insertion,
): { text: string; entities: ComposerEntity[] } => {
  const inserted = insertion.text
  const L = inserted.length
  const removed = to - from
  const text = state.text.slice(0, from) + inserted + state.text.slice(to)
  const active = new Set((insertion.marks ?? []).map(markKey))
  const out: ComposerEntity[] = []

  for (const e of state.entities) {
    const start = e.offset
    const end = e.offset + e.length
    if (end <= from) {
      out.push(e)
      continue
    }
    if (start >= to) {
      out.push({ ...e, offset: start + L - removed })
      continue
    }
    if (entityKind(e.type) !== "mark") continue
    const left = Math.max(0, from - start)
    const right = Math.max(0, end - to)
    if (active.has(entityMarkKey(e))) {
      out.push({ ...e, offset: Math.min(start, from), length: left + L + right })
    } else {
      if (left > 0) out.push({ ...e, offset: start, length: left })
      if (right > 0) out.push({ ...e, offset: from + L, length: right })
    }
  }
  if (L > 0) {
    for (const mark of insertion.marks ?? []) out.push(markEntity(mark, from, L))
    for (const e of insertion.entities ?? []) out.push({ ...e, offset: e.offset + from })
  }
  return { text, entities: normalizeEntities(text, out) }
}

/**
 * Apply a replacement and produce the next state with the caret at the end
 * of the inserted text. The range is expanded around atoms first. A no-op
 * edit returns `state` itself.
 */
export const replace = (
  state: DocState,
  range: Range,
  insertion: Insertion,
  options: { keepPendingMarks?: boolean; selection?: Selection } = {},
): DocState => {
  const { from, to } = expandRange(state, range)
  if (from === to && insertion.text.length === 0) return state
  const { text, entities } = replaceEntities(state, from, to, insertion)
  const caret = from + insertion.text.length
  const selection = normalizeSelection(text, entities, options.selection ?? collapsed(caret))
  if (text === state.text && entitiesEqual(entities, state.entities)) {
    if (sameSelection(selection, state.selection)) return state
    return { ...state, selection, pendingMarks: null }
  }
  return {
    text,
    entities,
    selection,
    pendingMarks: options.keepPendingMarks ? state.pendingMarks : null,
    revision: state.revision + 1,
  }
}

/** Replace text and entities wholesale (restoring a draft, an edit, undo). */
export const withContent = (
  state: DocState,
  content: { text: string; entities: readonly ComposerEntity[]; selection?: Selection },
): DocState => {
  const clean = normalizeText(content.text, content.entities)
  const text = clean.text
  const entities = normalizeEntities(text, clean.entities)
  const selection = normalizeSelection(text, entities, content.selection ?? collapsed(text.length))
  if (text === state.text && entitiesEqual(entities, state.entities)) {
    return sameSelection(selection, state.selection) ? state : { ...state, selection, pendingMarks: null }
  }
  return { text, entities, selection, pendingMarks: null, revision: state.revision + 1 }
}
