import type { UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  applyBoldShortcut,
  compareEntities,
  createDoc,
  deleteBackward,
  deleteForward,
  deleteRange,
  emptyHistory,
  entityKind,
  insertAtom,
  insertContent,
  insertLineBreak,
  insertText,
  markKey,
  markOf,
  normalizeEntities,
  record,
  redo,
  removeLink,
  selectAll,
  setLink,
  setSelection,
  splitsSurrogate,
  toggleMark,
  undo,
  type ComposerEntity,
  type DocState,
  type EditKind,
  type History,
  type MarkType,
} from "./index"

/**
 * Seeded random edit sequences. Each run prints its seed on failure; re-run
 * one with COMPOSER_SEED=<seed>.
 */

const mulberry32 = (seed: number) => {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const pieces = [
  "a",
  "b",
  " ",
  "word",
  "\n",
  "😀",
  "👨\u200D👩\u200D👧",
  "🇮🇷",
  "می\u200Cخواهم",
  "e\u0301",
  "日本語",
  "*",
  "**x**",
  "@",
  ":",
  "\r\n",
  "\u00A0",
]
const marks: MarkType[] = ["bold", "italic", "underline", "strikethrough", "code", "textUrl", "pre"]

type Rand = () => number
const int = (r: Rand, n: number) => Math.floor(r() * n)
const pick = <T>(r: Rand, list: readonly T[]): T => list[int(r, list.length)]!
const offset = (r: Rand, s: DocState) => {
  const x = r()
  if (x < 0.03) return -3
  if (x < 0.06) return s.text.length + 5
  if (x < 0.07) return Number.NaN
  return int(r, s.text.length + 1)
}

let atomSerial = 0

type Op = { name: string; kind: EditKind | "selection" | "undo" | "redo"; run: (s: DocState) => DocState }

const randomOp = (r: Rand, s: DocState): Op => {
  const choice = int(r, 17)
  switch (choice) {
    case 0:
    case 1:
    case 2: {
      const text = pick(r, pieces)
      return { name: `type ${JSON.stringify(text)}`, kind: "typing", run: (d) => insertText(d, text) }
    }
    case 3:
      return { name: "enter", kind: "structural", run: insertLineBreak }
    case 4: {
      const unit = pick(r, ["grapheme", "word", "line"] as const)
      return { name: `backspace ${unit}`, kind: "deleting", run: (d) => deleteBackward(d, unit) }
    }
    case 5: {
      const unit = pick(r, ["grapheme", "word", "line"] as const)
      return { name: `delete ${unit}`, kind: "deleting", run: (d) => deleteForward(d, unit) }
    }
    case 6: {
      const a = offset(r, s)
      const b = offset(r, s)
      return { name: `deleteRange ${a} ${b}`, kind: "structural", run: (d) => deleteRange(d, { from: a, to: b }) }
    }
    case 7:
    case 8: {
      const anchor = offset(r, s)
      const focus = r() < 0.5 ? anchor : offset(r, s)
      return { name: `select ${anchor} ${focus}`, kind: "selection", run: (d) => setSelection(d, { anchor, focus }) }
    }
    case 9: {
      const type = pick(r, marks)
      const mark = type === "textUrl" ? { type, url: pick(r, ["https://a.example", "https://b.example"]) } : { type }
      return { name: `toggle ${type}`, kind: "structural", run: (d) => toggleMark(d, mark) }
    }
    case 10: {
      const url = pick(r, ["https://a.example", "https://b.example"])
      return { name: `link ${url}`, kind: "structural", run: (d) => setLink(d, url) }
    }
    case 11:
      return { name: "unlink", kind: "structural", run: removeLink }
    case 12: {
      const id = String(++atomSerial)
      return {
        name: `mention ${id}`,
        kind: "structural",
        run: (d) => insertAtom(d, { type: "mention", userId: id as UserID }, `\uE000${id}\uE001`, { trailing: r() < 0.5 ? " " : "" }),
      }
    }
    case 13: {
      // Paste with random, possibly invalid, entities.
      const text = Array.from({ length: 1 + int(r, 4) }, () => pick(r, pieces)).join("")
      const entities: ComposerEntity[] = Array.from({ length: int(r, 4) }, () => ({
        type: pick(r, [...marks, "url"] as const),
        offset: int(r, text.length + 4) - 2,
        length: int(r, text.length + 4) - 1,
        url: "https://p.example",
      }))
      return { name: `paste ${JSON.stringify(text)}`, kind: "structural", run: (d) => insertContent(d, { text, entities }) }
    }
    case 14:
      return { name: "bold shortcut", kind: "structural", run: applyBoldShortcut }
    case 15:
      return { name: "undo", kind: "undo", run: (d) => d }
    default:
      return r() < 0.5
        ? { name: "redo", kind: "redo", run: (d) => d }
        : { name: "select all", kind: "selection", run: selectAll }
  }
}

const checkInvariants = (s: DocState) => {
  const { text, entities, selection } = s
  // Sorted, in bounds, non-degenerate, canonical.
  for (let i = 0; i < entities.length; i++) {
    const e = entities[i]!
    expect(Number.isInteger(e.offset) && Number.isInteger(e.length)).toBe(true)
    expect(e.offset).toBeGreaterThanOrEqual(0)
    expect(e.length).toBeGreaterThan(0)
    expect(e.offset + e.length).toBeLessThanOrEqual(text.length)
    expect(splitsSurrogate(text, e.offset)).toBe(false)
    expect(splitsSurrogate(text, e.offset + e.length)).toBe(false)
    if (i > 0) expect(compareEntities(entities[i - 1]!, e)).toBeLessThan(0)
  }
  expect(normalizeEntities(text, entities)).toEqual(entities)

  // Atoms: whole, on one line, never overlapping, never cut by a mark.
  const atoms = entities.filter((e) => entityKind(e.type) === "atom")
  for (const atom of atoms) {
    const label = text.slice(atom.offset, atom.offset + atom.length)
    expect(label).toBe(`\uE000${atom.userId}\uE001`)
    for (const other of entities) {
      if (other === atom) continue
      const end = other.offset + other.length
      const atomEnd = atom.offset + atom.length
      if (entityKind(other.type) === "atom") expect(end <= atom.offset || other.offset >= atomEnd).toBe(true)
      expect(other.offset > atom.offset && other.offset < atomEnd).toBe(false)
      expect(end > atom.offset && end < atomEnd).toBe(false)
    }
  }

  // Atom labels use private-use brackets nothing else inserts, so a bracket
  // outside an atom is the remnant of an atom that was cut.
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (ch === "\uE000") expect(atoms.some((a) => a.offset === i)).toBe(true)
    if (ch === "\uE001") expect(atoms.some((a) => a.offset + a.length === i + 1)).toBe(true)
  }

  // Equal marks never overlap or touch.
  const byKey = new Map<string, ComposerEntity[]>()
  for (const e of entities) {
    if (entityKind(e.type) !== "mark") continue
    const key = markKey(markOf(e))
    byKey.set(key, [...(byKey.get(key) ?? []), e])
  }
  for (const list of byKey.values()) {
    for (let i = 1; i < list.length; i++) {
      expect(list[i]!.offset).toBeGreaterThan(list[i - 1]!.offset + list[i - 1]!.length)
    }
  }

  // Selection in bounds, not inside an atom or a surrogate pair.
  for (const point of [selection.anchor, selection.focus]) {
    expect(point).toBeGreaterThanOrEqual(0)
    expect(point).toBeLessThanOrEqual(text.length)
    expect(splitsSurrogate(text, point)).toBe(false)
    for (const atom of atoms) expect(point > atom.offset && point < atom.offset + atom.length).toBe(false)
  }

  // Only `\n` line breaks and no non-breaking spaces survive.
  expect(/[\r\u00A0\u2028\u2029]/.test(text)).toBe(false)
}

const content = (s: DocState) => ({ text: s.text, entities: s.entities, selection: s.selection })

const runSequence = (seed: number, steps: number) => {
  const r = mulberry32(seed)
  let state = createDoc()
  let history: History = emptyHistory()
  let now = 0
  const log: string[] = []
  const initial = content(state)
  try {
    for (let i = 0; i < steps; i++) {
      now += int(r, 1500)
      const op = randomOp(r, state)
      log.push(op.name)
      const before = state
      if (op.kind === "undo" || op.kind === "redo") {
        const result = op.kind === "undo" ? undo(history, state) : redo(history, state)
        if (result) {
          // Undo then redo (or the reverse) returns to the same content.
          const back = op.kind === "undo" ? redo(result.history, result.state) : undo(result.history, result.state)
          expect(back && content(back.state)).toEqual(content(before))
          ;({ history, state } = result)
        }
      } else {
        state = op.run(state)
        if (op.kind === "selection") history = { ...history, lastKind: null }
        else history = record(history, before, state, op.kind, now, { limit: 1000 })
        if (state !== before && (state.text !== before.text || state.entities !== before.entities)) {
          expect(state.revision).toBeGreaterThan(before.revision)
        }
      }
      checkInvariants(state)
    }
    // Undo everything: back to the start.
    for (;;) {
      const result = undo(history, state)
      if (!result) break
      ;({ history, state } = result)
    }
    expect(content(state).text).toBe(initial.text)
    expect(content(state).entities).toEqual(initial.entities)
  } catch (error) {
    throw new Error(`seed ${seed} failed after: ${log.slice(-12).join(" | ")}\n${String(error)}`, { cause: error })
  }
}

describe("random edit sequences", () => {
  const fixed = Number(process.env["COMPOSER_SEED"] ?? Number.NaN)
  const seeds = Number.isFinite(fixed) ? [fixed] : Array.from({ length: 300 }, (_, i) => 1000 + i)

  it(`keep every invariant (${seeds.length} seeds × 120 steps)`, () => {
    for (const seed of seeds) runSequence(seed, 120)
  })
})
