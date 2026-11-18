import type { Entity, EntityType } from "@inline/core-protocol"

/**
 * An entity as the composer keeps it: the wire `Entity` plus the fields the
 * contract does not carry yet. Structurally it is still an `Entity`, so a
 * document's entities can be sent as they are.
 *
 * TODO(contract): `Entity` has no field for a group mention's group ID.
 * Until core-protocol adds one, `groupId` lives here and is dropped by
 * anything that only knows `Entity`.
 */
export type ComposerEntity = Entity & { groupId?: string }

/** A range of UTF-16 offsets, `from <= to`. */
export type Range = { from: number; to: number }

/**
 * Anchor is where the selection started, focus is where the caret is. Both
 * are UTF-16 offsets into the text. Collapsed when equal.
 */
export type Selection = { anchor: number; focus: number }

/** Formatting that wraps text and grows when the user types inside it. */
export type MarkType =
  | "bold"
  | "italic"
  | "underline"
  | "strikethrough"
  | "code"
  | "pre"
  | "textUrl"
  | "highlight"
  | "blockquote"

/** Indivisible ranges, rendered as non-editable chips. */
export type AtomType = "mention" | "groupMention" | "thread"

/** A mark with its attributes, without a position. */
export type Mark = {
  type: MarkType
  url?: string
  language?: string
}

/**
 * One revision of the composer. Immutable: every operation returns a new
 * state. `revision` increases on every change to text or entities and never
 * goes back, not even on undo; a selection-only change keeps it.
 */
export type DocState = {
  readonly text: string
  readonly entities: readonly ComposerEntity[]
  readonly selection: Selection
  /**
   * Marks the next text inserted at a collapsed caret gets, set by toggling a
   * mark with nothing selected. `null` means "inherit from the marks around
   * the caret". Cleared when the selection moves.
   */
  readonly pendingMarks: readonly Mark[] | null
  readonly revision: number
}

/** How an entity type behaves under edits. */
export type EntityKind = "mark" | "atom" | "derived"

const markTypes: ReadonlySet<EntityType> = new Set<MarkType>([
  "bold",
  "italic",
  "underline",
  "strikethrough",
  "code",
  "pre",
  "textUrl",
  "highlight",
  "blockquote",
])

const atomTypes: ReadonlySet<EntityType> = new Set<AtomType>(["mention", "groupMention", "thread"])

/**
 * - `mark`: formatting. Grows when typing strictly inside, splits, merges.
 * - `atom`: a mention or reference. Never split; edited only as a whole.
 * - `derived`: detected by the server (`url`, `email`, `botCommand`...).
 *   Kept while untouched, dropped as soon as an edit touches its inside.
 */
export const entityKind = (type: EntityType): EntityKind =>
  markTypes.has(type) ? "mark" : atomTypes.has(type) ? "atom" : "derived"

export const isMarkType = (type: EntityType): type is MarkType => markTypes.has(type)
export const isAtomType = (type: EntityType): type is AtomType => atomTypes.has(type)
