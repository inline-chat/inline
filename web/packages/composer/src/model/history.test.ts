import { describe, expect, it } from "vitest"
import {
  collapsed,
  createDoc,
  deleteBackward,
  emptyHistory,
  insertLineBreak,
  insertText,
  markBoundary,
  record,
  redo,
  setSelection,
  toggleMark,
  undo,
  type DocState,
  type EditKind,
  type History,
} from "./index"

/** A tiny harness: apply an edit, record it, keep the clock. */
const session = (initial: DocState = createDoc()) => {
  let state = initial
  let history: History = emptyHistory()
  let now = 0
  const edit = (fn: (s: DocState) => DocState, kind: EditKind) => {
    const next = fn(state)
    history = record(history, state, next, kind, now, { limit: 5, pauseMs: 1000 })
    state = next
  }
  return {
    get state() {
      return state
    },
    get history() {
      return history
    },
    tick: (ms: number) => {
      now += ms
    },
    type: (text: string) => {
      for (const ch of text) edit((s) => insertText(s, ch), "typing")
    },
    backspace: () => edit((s) => deleteBackward(s), "deleting"),
    edit,
    move: (offset: number) => {
      state = setSelection(state, collapsed(offset))
      history = markBoundary(history)
    },
    undo: () => {
      const r = undo(history, state)
      if (r) ({ history, state } = r)
      return r !== null
    },
    redo: () => {
      const r = redo(history, state)
      if (r) ({ history, state } = r)
      return r !== null
    },
  }
}

describe("history", () => {
  it("coalesces consecutive typing into one step", () => {
    const s = session()
    s.type("hello")
    expect(s.history.undo).toHaveLength(1)
    s.undo()
    expect(s.state.text).toBe("")
    s.redo()
    expect(s.state.text).toBe("hello")
    expect(s.state.selection).toEqual(collapsed(5))
  })

  it("starts a new step after a pause", () => {
    const s = session()
    s.type("ab")
    s.tick(1500)
    s.type("cd")
    s.undo()
    expect(s.state.text).toBe("ab")
  })

  it("starts a new step after a selection move and restores that selection on undo", () => {
    const s = session(createDoc({ text: "xyz" }))
    s.type("ab")
    s.move(0)
    s.type("12")
    expect(s.state.text).toBe("12xyzab")
    s.undo()
    expect(s.state.text).toBe("xyzab")
    expect(s.state.selection).toEqual(collapsed(0))
    s.undo()
    expect(s.state.text).toBe("xyz")
    expect(s.state.selection).toEqual(collapsed(3))
  })

  it("keeps typing and deleting in separate steps, structural edits alone", () => {
    const s = session()
    s.type("abc")
    s.backspace()
    s.backspace()
    s.edit(insertLineBreak, "structural")
    s.type("d")
    expect(s.state.text).toBe("a\nd")
    s.undo()
    expect(s.state.text).toBe("a\n")
    s.undo()
    expect(s.state.text).toBe("a")
    s.undo()
    expect(s.state.text).toBe("abc")
    s.undo()
    expect(s.state.text).toBe("")
    expect(s.undo()).toBe(false)
  })

  it("restores entities, clears redo on a new edit and caps the history", () => {
    const s = session(createDoc({ text: "word" }))
    s.edit((d) => toggleMark(setSelection(d, { anchor: 0, focus: 4 }), "bold"), "structural")
    expect(s.state.entities).toHaveLength(1)
    s.undo()
    expect(s.state.entities).toHaveLength(0)
    s.edit((d) => insertText(d, "!"), "structural")
    expect(s.redo()).toBe(false)
    for (let i = 0; i < 10; i++) s.edit((d) => insertText(d, String(i)), "structural")
    expect(s.history.undo).toHaveLength(5)
  })

  it("moves the revision forward on undo and redo", () => {
    const s = session()
    s.type("a")
    const r1 = s.state.revision
    s.undo()
    expect(s.state.revision).toBeGreaterThan(r1)
    const r2 = s.state.revision
    s.redo()
    expect(s.state.revision).toBeGreaterThan(r2)
  })

  it("ignores selection-only changes", () => {
    const h = emptyHistory()
    const a = createDoc({ text: "ab" })
    expect(record(h, a, setSelection(a, collapsed(0)), "typing", 0)).toBe(h)
  })
})
