import type { ChatID, UserID } from "@inline/ids"
import {
  activeMarks,
  expandRange,
  isCollapsed,
  normalizeSelection,
  replace,
  selectionRange,
  type Insertion,
} from "./doc"
import {
  entityMarkKey,
  markEntity,
  markKey,
  normalizeEntities,
  splitsSurrogate,
  uniqueMarks,
} from "./entities"
import {
  lineEndOf,
  lineStartOf,
  nextGrapheme,
  nextWordBoundary,
  previousGrapheme,
  previousWordBoundary,
} from "./segment"
import { normalizeText } from "./text"
import {
  entityKind,
  type ComposerEntity,
  type DocState,
  type Mark,
  type MarkType,
  type Range,
} from "./types"

/**
 * Pure operations on a document. Each returns a new state, or the same
 * state object when nothing changed. None of them throw for any input
 * offsets: ranges are clamped and expanded around atoms.
 */

// ---------------------------------------------------------------------------
// Text

/**
 * Type `text` over the selection (or at `range`). The inserted text takes
 * the active marks: pending marks at the caret, else the marks strictly
 * around it. Pending marks survive typing so "toggle bold, type a word" works.
 */
export const insertText = (state: DocState, text: string, range?: Range): DocState => {
  const clean = normalizeText(text).text
  const target = expandRange(state, range ?? selectionRange(state.selection))
  if (clean.length === 0 && target.from === target.to) return state
  const marks = activeMarks(state, target)
  const continuing = range === undefined && isCollapsed(state.selection)
  return replace(state, target, { text: clean, marks }, { keepPendingMarks: continuing })
}

/** Replace a range with text and its own entities (paste, autocomplete). */
export const replaceRange = (
  state: DocState,
  range: Range,
  content: { text: string; entities?: readonly ComposerEntity[] },
  options: { inheritMarks?: boolean } = {},
): DocState => {
  const clean = normalizeText(content.text, content.entities ?? [])
  const target = expandRange(state, range)
  const insertion: Insertion = { text: clean.text, entities: clean.entities }
  if (options.inheritMarks ?? true) insertion.marks = activeMarks(state, target)
  return replace(state, target, insertion)
}

/** Insert content at the selection, replacing it. */
export const insertContent = (
  state: DocState,
  content: { text: string; entities?: readonly ComposerEntity[] },
): DocState => replaceRange(state, selectionRange(state.selection), content)

export const insertLineBreak = (state: DocState): DocState => insertText(state, "\n")

/** Delete a range. The range grows to cover any atom it touches. */
export const deleteRange = (state: DocState, range: Range): DocState => {
  const target = expandRange(state, range)
  if (target.from === target.to) return state
  return replace(state, target, { text: "" })
}

export const deleteSelection = (state: DocState): DocState =>
  deleteRange(state, selectionRange(state.selection))

export type DeleteUnit = "grapheme" | "word" | "line"

/**
 * The range a backward or forward deletion would remove, without removing
 * it: the selection when it is not collapsed, else one unit from the caret.
 * Grown to whole atoms, so deleting next to a mention removes all of it.
 */
export const deletionRange = (
  state: DocState,
  direction: "backward" | "forward",
  unit: DeleteUnit,
): Range => {
  if (!isCollapsed(state.selection)) return expandRange(state, selectionRange(state.selection))
  const { text } = state
  const caret = state.selection.focus
  let other: number
  if (direction === "backward") {
    if (unit === "grapheme") other = previousGrapheme(text, caret)
    else if (unit === "word") other = previousWordBoundary(text, caret)
    else {
      const start = lineStartOf(text, caret)
      other = start === caret ? Math.max(0, caret - 1) : start
    }
  } else if (unit === "grapheme") other = nextGrapheme(text, caret)
  else if (unit === "word") other = nextWordBoundary(text, caret)
  else {
    const end = lineEndOf(text, caret)
    other = end === caret ? Math.min(text.length, caret + 1) : end
  }
  return expandRange(state, { from: Math.min(caret, other), to: Math.max(caret, other) })
}

export const deleteBackward = (state: DocState, unit: DeleteUnit = "grapheme"): DocState =>
  deleteRange(state, deletionRange(state, "backward", unit))

export const deleteForward = (state: DocState, unit: DeleteUnit = "grapheme"): DocState =>
  deleteRange(state, deletionRange(state, "forward", unit))

// ---------------------------------------------------------------------------
// Marks

/** Every character in [from, to) except line breaks is inside a mark accepted by `matches`. */
const coveredBy = (
  state: DocState,
  matches: (e: ComposerEntity) => boolean,
  from: number,
  to: number,
): boolean => {
  const spans = state.entities
    .filter((e) => entityKind(e.type) === "mark" && matches(e))
    .map((e) => [e.offset, e.offset + e.length] as const)
  for (let i = from; i < to; i++) {
    if (state.text[i] === "\n") continue
    if (!spans.some(([s, e]) => s <= i && i < e)) return false
  }
  return true
}

const hasContent = (text: string, from: number, to: number): boolean => {
  for (let i = from; i < to; i++) if (text[i] !== "\n") return true
  return false
}

const removeMarkRange = (
  entities: readonly ComposerEntity[],
  matches: (e: ComposerEntity) => boolean,
  from: number,
  to: number,
): ComposerEntity[] => {
  const out: ComposerEntity[] = []
  for (const e of entities) {
    const end = e.offset + e.length
    if (!matches(e) || end <= from || e.offset >= to) {
      out.push(e)
      continue
    }
    if (e.offset < from) out.push({ ...e, length: from - e.offset })
    if (end > to) out.push({ ...e, offset: to, length: end - to })
  }
  return out
}

const withEntities = (state: DocState, entities: ComposerEntity[]): DocState => {
  const normalized = normalizeEntities(state.text, entities)
  const selection = normalizeSelection(state.text, normalized, state.selection)
  return { ...state, entities: normalized, selection, revision: state.revision + 1 }
}

/**
 * Whether a mark of `type` is on for the selection: over every character of
 * a range, or active at a caret (pending marks included). Attributes such as
 * a link's URL are ignored.
 */
export const isMarkActive = (state: DocState, type: MarkType): boolean => {
  const range = selectionRange(state.selection)
  if (range.from === range.to) return activeMarks(state, range).some((m) => m.type === type)
  if (!hasContent(state.text, range.from, range.to)) return false
  return coveredBy(state, (e) => e.type === type, range.from, range.to)
}

/**
 * Toggle a mark over the selection. With a range: if every character (line
 * breaks aside) already has the mark, remove it; otherwise add it to all.
 * At a caret: toggle it in the pending marks for the next insertion.
 */
export const toggleMark = (state: DocState, mark: Mark | MarkType, rangeArg?: Range): DocState => {
  const m: Mark = typeof mark === "string" ? { type: mark } : mark
  const key = markKey(m)
  const range = expandRange(state, rangeArg ?? selectionRange(state.selection))
  if (range.from === range.to) {
    const current = activeMarks(state, range)
    const has = current.some((a) => markKey(a) === key)
    const pending = has ? current.filter((a) => markKey(a) !== key) : uniqueMarks([...current, m])
    return { ...state, pendingMarks: pending }
  }
  if (!hasContent(state.text, range.from, range.to)) return state
  if (coveredBy(state, (e) => entityMarkKey(e) === key, range.from, range.to)) {
    return withEntities(
      state,
      removeMarkRange(
        state.entities,
        (e) => entityKind(e.type) === "mark" && entityMarkKey(e) === key,
        range.from,
        range.to,
      ),
    )
  }
  return withEntities(state, [
    ...state.entities,
    markEntity(m, range.from, range.to - range.from),
  ])
}

/** The link (`textUrl`) at the caret or over the start of the selection. */
export const linkAt = (state: DocState): ComposerEntity | undefined => {
  const { from, to } = selectionRange(state.selection)
  return state.entities.find(
    (e) =>
      e.type === "textUrl" &&
      (from === to ? e.offset <= from && from <= e.offset + e.length : e.offset <= from && from < e.offset + e.length),
  )
}

/**
 * Link the selection to `url` (already checked by the caller's URL policy).
 * Any link overlapping the range is replaced. With a collapsed caret inside
 * a link, that link's URL changes; elsewhere the URL itself is inserted as
 * linked text.
 */
export const setLink = (state: DocState, url: string, label?: string): DocState => {
  const range = expandRange(state, selectionRange(state.selection))
  if (range.from === range.to) {
    const existing = linkAt(state)
    if (existing && label === undefined) {
      const others = state.entities.filter((e) => e !== existing)
      return withEntities(state, [...others, { ...existing, url }])
    }
    const text = label ?? url
    return replace(state, range, { text, entities: [{ type: "textUrl", offset: 0, length: text.length, url }] })
  }
  const without = removeMarkRange(state.entities, (e) => e.type === "textUrl", range.from, range.to)
  return withEntities(state, [...without, markEntity({ type: "textUrl", url }, range.from, range.to - range.from)])
}

/** Remove links over the selection, or the whole link at a collapsed caret. */
export const removeLink = (state: DocState): DocState => {
  const range = selectionRange(state.selection)
  if (range.from === range.to) {
    const existing = linkAt(state)
    if (!existing) return state
    return withEntities(state, state.entities.filter((e) => e !== existing))
  }
  const next = removeMarkRange(state.entities, (e) => e.type === "textUrl", range.from, range.to)
  if (next.length === state.entities.length && next.every((e, i) => e === state.entities[i])) return state
  return withEntities(state, next)
}

// ---------------------------------------------------------------------------
// Atoms

export type AtomSpec =
  | { type: "mention"; userId: UserID }
  | { type: "groupMention"; groupId: string }
  | { type: "thread"; chatId: ChatID }

const atomEntity = (spec: AtomSpec, length: number): ComposerEntity => {
  switch (spec.type) {
    case "mention":
      return { type: "mention", offset: 0, length, userId: spec.userId }
    case "groupMention":
      return { type: "groupMention", offset: 0, length, groupId: spec.groupId }
    case "thread":
      return { type: "thread", offset: 0, length, chatId: spec.chatId }
  }
}

/**
 * Replace `range` (default: the selection) with an atom showing `label`,
 * followed by `trailing` (a space by default) as plain text. Line breaks in
 * the label become spaces: an atom never spans lines.
 */
export const insertAtom = (
  state: DocState,
  spec: AtomSpec,
  label: string,
  options: { range?: Range; trailing?: string } = {},
): DocState => {
  const clean = normalizeText(label).text.replace(/\n/g, " ")
  if (clean.length === 0) return state
  const trailing = options.trailing ?? " "
  const target = expandRange(state, options.range ?? selectionRange(state.selection))
  return replace(state, target, {
    text: clean + trailing,
    entities: [atomEntity(spec, clean.length)],
    marks: activeMarks(state, target),
  })
}

// ---------------------------------------------------------------------------
// Whole-document helpers

/** Select everything. */
export const selectAll = (state: DocState): DocState =>
  state.selection.anchor === 0 && state.selection.focus === state.text.length
    ? state
    : { ...state, selection: { anchor: 0, focus: state.text.length }, pendingMarks: null }

/**
 * The text and entities to send: leading and trailing whitespace (spaces,
 * tabs, line breaks) removed, entities clipped and shifted to match.
 */
export const trimmedContent = (
  state: Pick<DocState, "text" | "entities">,
): { text: string; entities: ComposerEntity[] } => {
  const { text } = state
  let start = 0
  let end = text.length
  while (start < end && /\s/u.test(text[start]!)) start++
  while (end > start && /\s/u.test(text[end - 1]!)) end--
  const trimmed = text.slice(start, end)
  const entities: ComposerEntity[] = []
  for (const e of state.entities) {
    const s = Math.max(e.offset, start)
    const t = Math.min(e.offset + e.length, end)
    if (t <= s) continue
    // An atom cut by trimming cannot happen (labels have no outer whitespace
    // we add), but drop it rather than send half a mention.
    if (entityKind(e.type) === "atom" && (s !== e.offset || t !== e.offset + e.length)) continue
    entities.push({ ...e, offset: s - start, length: t - s })
  }
  return { text: trimmed, entities: normalizeEntities(trimmed, entities) }
}

/** The marks at the caret, for toolbar state. */
export const marksAtSelection = (state: DocState): Mark[] =>
  activeMarks(state, selectionRange(state.selection)).map((m) => ({ ...m }))


/** Text and entities inside `range` (default: the selection), offsets relative to it. */
export const sliceContent = (
  state: Pick<DocState, "text" | "entities" | "selection">,
  rangeArg?: Range,
): { text: string; entities: ComposerEntity[] } => {
  const { from, to } = expandRange(state, rangeArg ?? selectionRange(state.selection))
  const text = state.text.slice(from, to)
  const entities: ComposerEntity[] = []
  for (const e of state.entities) {
    const s = Math.max(e.offset, from)
    const t = Math.min(e.offset + e.length, to)
    if (t <= s) continue
    entities.push({ ...e, offset: s - from, length: t - s })
  }
  return { text, entities: normalizeEntities(text, entities) }
}

/**
 * Where a text change read back from the DOM happened: the replaced range in
 * `before` and the inserted text. `caret` (the collapsed caret after the
 * change) picks the right place when the change is ambiguous, as when
 * typing `a` in `aa`. Ranges never split a surrogate pair.
 */
export const diffText = (
  before: string,
  after: string,
  caret?: number,
): { from: number; to: number; inserted: string } | null => {
  if (before === after) return null
  const delta = after.length - before.length
  if (caret !== undefined && caret >= 0 && caret <= after.length) {
    if (delta > 0 && caret - delta >= 0) {
      const start = caret - delta
      if (before.slice(0, start) === after.slice(0, start) && before.slice(start) === after.slice(caret)) {
        return { from: start, to: start, inserted: after.slice(start, caret) }
      }
    }
    if (delta < 0 && caret <= before.length) {
      if (before.slice(0, caret) === after.slice(0, caret) && before.slice(caret - delta) === after.slice(caret)) {
        return { from: caret, to: caret - delta, inserted: "" }
      }
    }
  }
  let prefix = 0
  const max = Math.min(before.length, after.length)
  while (prefix < max && before.charCodeAt(prefix) === after.charCodeAt(prefix)) prefix++
  let suffix = 0
  while (
    suffix < max - prefix &&
    before.charCodeAt(before.length - 1 - suffix) === after.charCodeAt(after.length - 1 - suffix)
  ) {
    suffix++
  }
  let from = prefix
  let toBefore = before.length - suffix
  let toAfter = after.length - suffix
  // Keep surrogate pairs whole on both sides.
  while (from > 0 && (splitsSurrogate(before, from) || splitsSurrogate(after, from))) from--
  while (toBefore < before.length && (splitsSurrogate(before, toBefore) || splitsSurrogate(after, toAfter))) {
    toBefore++
    toAfter++
  }
  return { from, to: toBefore, inserted: after.slice(from, toAfter) }
}
