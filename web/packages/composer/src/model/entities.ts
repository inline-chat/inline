import { entityKind, isMarkType, type ComposerEntity, type Mark } from "./types"

// ---------------------------------------------------------------------------
// UTF-16 helpers

export const isHighSurrogate = (code: number): boolean => code >= 0xd800 && code <= 0xdbff
export const isLowSurrogate = (code: number): boolean => code >= 0xdc00 && code <= 0xdfff

/** True when `offset` falls between the two halves of a surrogate pair. */
export const splitsSurrogate = (text: string, offset: number): boolean =>
  offset > 0 &&
  offset < text.length &&
  isLowSurrogate(text.charCodeAt(offset)) &&
  isHighSurrogate(text.charCodeAt(offset - 1))

/** Move an offset off the middle of a surrogate pair, toward `bias`. */
export const snapSurrogate = (text: string, offset: number, bias: "back" | "forward"): number =>
  splitsSurrogate(text, offset) ? (bias === "back" ? offset - 1 : offset + 1) : offset

export const clamp = (value: number, min: number, max: number): number =>
  value < min ? min : value > max ? max : value

// ---------------------------------------------------------------------------
// Marks

export const markOf = (entity: ComposerEntity): Mark => {
  if (!isMarkType(entity.type)) throw new Error(`not a mark: ${entity.type}`)
  const mark: Mark = { type: entity.type }
  if (entity.type === "textUrl" && entity.url !== undefined) mark.url = entity.url
  if (entity.type === "pre" && entity.language !== undefined) mark.language = entity.language
  return mark
}

/** Identity of a mark: same key means the two can merge. */
export const markKey = (mark: Mark): string =>
  mark.type === "textUrl"
    ? `textUrl ${mark.url ?? ""}`
    : mark.type === "pre"
      ? `pre ${mark.language ?? ""}`
      : mark.type

export const entityMarkKey = (entity: ComposerEntity): string => markKey(markOf(entity))

export const markEntity = (mark: Mark, offset: number, length: number): ComposerEntity => {
  const entity: ComposerEntity = { type: mark.type, offset, length }
  if (mark.url !== undefined) entity.url = mark.url
  if (mark.language !== undefined) entity.language = mark.language
  return entity
}

export const sameMarks = (a: readonly Mark[], b: readonly Mark[]): boolean => {
  if (a.length !== b.length) return false
  const keys = new Set(a.map(markKey))
  return b.every((mark) => keys.has(markKey(mark)))
}

/** Marks sorted by key, without duplicates. */
export const uniqueMarks = (marks: readonly Mark[]): Mark[] => {
  const byKey = new Map<string, Mark>()
  for (const mark of marks) byKey.set(markKey(mark), mark)
  return [...byKey.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([, m]) => m)
}

// ---------------------------------------------------------------------------
// Ordering and normalization

const attrKey = (e: ComposerEntity): string =>
  `${e.url ?? ""}\u0000${e.language ?? ""}\u0000${e.userId ?? ""}\u0000${e.chatId ?? ""}\u0000${e.groupId ?? ""}`

/** Offset ascending, outer before inner, then type and attributes. */
export const compareEntities = (a: ComposerEntity, b: ComposerEntity): number =>
  a.offset - b.offset ||
  b.length - a.length ||
  (a.type < b.type ? -1 : a.type > b.type ? 1 : 0) ||
  (attrKey(a) < attrKey(b) ? -1 : attrKey(a) > attrKey(b) ? 1 : 0)

const copy = (e: ComposerEntity, offset: number, length: number): ComposerEntity => ({
  ...e,
  offset,
  length,
})

/**
 * Bring a list of entities into canonical form for `text`:
 *
 * - offsets are integers within `[0, text.length]`, lengths positive;
 * - no boundary splits a surrogate pair (ranges grow to cover the pair);
 * - atoms never contain a line break and never overlap another atom;
 * - a mark that partly covers an atom grows to cover all of it;
 * - derived entities that overlap an atom are dropped;
 * - equal marks that overlap or touch are merged into one;
 * - the result is sorted by `compareEntities` and has no duplicates.
 *
 * Idempotent: normalizing a normalized list returns an equal list.
 */
export const normalizeEntities = (
  text: string,
  entities: readonly ComposerEntity[],
): ComposerEntity[] => {
  const len = text.length
  const atoms: ComposerEntity[] = []
  const marks: ComposerEntity[] = []
  const derived: ComposerEntity[] = []

  for (const raw of entities) {
    if (!Number.isFinite(raw.offset) || !Number.isFinite(raw.length)) continue
    let start = clamp(Math.trunc(raw.offset), 0, len)
    let end = clamp(Math.trunc(raw.offset + raw.length), start, len)
    start = snapSurrogate(text, start, "back")
    end = snapSurrogate(text, end, "forward")
    if (end <= start) continue
    const entity = copy(raw, start, end - start)
    const kind = entityKind(entity.type)
    if (kind === "atom") atoms.push(entity)
    else if (kind === "mark") marks.push(entity)
    else derived.push(entity)
  }

  // Atoms: no line breaks, no overlaps (the earlier one wins).
  atoms.sort(compareEntities)
  const keptAtoms: ComposerEntity[] = []
  let atomEnd = -1
  for (const atom of atoms) {
    if (atom.offset < atomEnd) continue
    if (text.slice(atom.offset, atom.offset + atom.length).includes("\n")) continue
    keptAtoms.push(atom)
    atomEnd = atom.offset + atom.length
  }

  const overlapsAtom = (start: number, end: number): boolean =>
    keptAtoms.some((a) => start < a.offset + a.length && end > a.offset)

  // Marks: grow over partly covered atoms, then merge equal ones.
  const grouped = new Map<string, ComposerEntity[]>()
  for (const mark of marks) {
    let start = mark.offset
    let end = mark.offset + mark.length
    for (const atom of keptAtoms) {
      const aEnd = atom.offset + atom.length
      if (start > atom.offset && start < aEnd) start = atom.offset
      if (end > atom.offset && end < aEnd) end = aEnd
    }
    const key = entityMarkKey(mark)
    const list = grouped.get(key)
    const grown = copy(mark, start, end - start)
    if (list) list.push(grown)
    else grouped.set(key, [grown])
  }
  const mergedMarks: ComposerEntity[] = []
  for (const list of grouped.values()) {
    list.sort((a, b) => a.offset - b.offset)
    let current: ComposerEntity | undefined
    for (const mark of list) {
      if (current && mark.offset <= current.offset + current.length) {
        const end = Math.max(current.offset + current.length, mark.offset + mark.length)
        current = copy(current, current.offset, end - current.offset)
        continue
      }
      if (current) mergedMarks.push(current)
      current = mark
    }
    if (current) mergedMarks.push(current)
  }

  const keptDerived = derived.filter((e) => !overlapsAtom(e.offset, e.offset + e.length))

  const all = [...keptAtoms, ...mergedMarks, ...keptDerived].sort(compareEntities)
  const result: ComposerEntity[] = []
  for (const entity of all) {
    const last = result[result.length - 1]
    if (last && compareEntities(last, entity) === 0) continue
    result.push(entity)
  }
  return result
}

/** The atom whose inside (not its edges) contains `offset`, if any. */
export const atomContaining = (
  entities: readonly ComposerEntity[],
  offset: number,
): ComposerEntity | undefined =>
  entities.find(
    (e) => entityKind(e.type) === "atom" && e.offset < offset && offset < e.offset + e.length,
  )

/** Atoms that intersect the inside of `[from, to)`. */
export const atomsIntersecting = (
  entities: readonly ComposerEntity[],
  from: number,
  to: number,
): ComposerEntity[] =>
  entities.filter(
    (e) => entityKind(e.type) === "atom" && from < e.offset + e.length && to > e.offset,
  )

export const entitiesEqual = (
  a: readonly ComposerEntity[],
  b: readonly ComposerEntity[],
): boolean => a.length === b.length && a.every((e, i) => compareEntities(e, b[i]!) === 0)
