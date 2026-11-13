import { describe, expect, test } from "bun:test"
import type { Doc } from "./doc.js"
import { ProgressPresenter, ProgressStream, type ProgressTransport } from "./presenter.js"
import type { RenderOp } from "./renderer.js"

type Call = { op: "send" | "edit"; id: bigint; text: string }

function fakeClock() {
  let now = 0
  let timers: Array<{ at: number; callback: () => void; id: number }> = []
  let nextId = 1
  return {
    now: () => now,
    setTimer: (callback: () => void, ms: number) => {
      const id = nextId++
      timers.push({ at: now + ms, callback, id })
      return id
    },
    clearTimer: (id: unknown) => {
      timers = timers.filter((timer) => timer.id !== id)
    },
    async advance(ms: number) {
      now += ms
      const due = timers.filter((timer) => timer.at <= now)
      timers = timers.filter((timer) => timer.at > now)
      for (const timer of due) timer.callback()
      await Promise.resolve()
    },
    pending: () => timers.length,
  }
}

function transport(calls: Call[], options: { failEdits?: boolean } = {}): ProgressTransport {
  let next = 100n
  return {
    async send(doc: Doc) {
      const id = next++
      calls.push({ op: "send", id, text: doc.text })
      return id
    },
    async edit(id: bigint, doc: Doc) {
      if (options.failEdits) throw new Error("MESSAGE_ID_INVALID")
      calls.push({ op: "edit", id, text: doc.text })
    },
  }
}

const doc = (text: string): Doc => ({ text, blockContent: { blocks: [] } })
const progress = (slot: number, text: string, urgent = false): RenderOp => ({ type: "progress", slot, doc: doc(text), urgent })
const end = (slot: number, text: string): RenderOp => ({ type: "end", slot, doc: doc(text) })

describe("ProgressPresenter", () => {
  test("sends once, coalesces ordinary edits and flushes the last one", async () => {
    const calls: Call[] = []
    const clock = fakeClock()
    const presenter = new ProgressPresenter(transport(calls), { editIntervalMs: 1_000, ...clock })
    presenter.push([progress(1, "a")])
    await presenter.flush()
    presenter.push([progress(1, "b")])
    presenter.push([progress(1, "c")])
    await Promise.resolve()
    expect(calls).toEqual([{ op: "send", id: 100n, text: "a" }])
    await clock.advance(1_000)
    await presenter.flush()
    expect(calls).toEqual([
      { op: "send", id: 100n, text: "a" },
      { op: "edit", id: 100n, text: "c" },
    ])
  })

  test("urgent and final edits skip the wait; nothing follows the end", async () => {
    const calls: Call[] = []
    const clock = fakeClock()
    const presenter = new ProgressPresenter(transport(calls), { editIntervalMs: 1_000, ...clock })
    presenter.push([progress(1, "a")])
    await presenter.flush()
    presenter.push([progress(1, "waiting", true)])
    await presenter.flush()
    presenter.push([end(1, "Worked for 1s")])
    presenter.push([progress(1, "late")])
    await presenter.flush()
    expect(calls.map((call) => call.text)).toEqual(["a", "waiting", "Worked for 1s"])
    expect(clock.pending()).toBe(0)
  })

  test("a new slot sends a new message after the previous one ends", async () => {
    const calls: Call[] = []
    const presenter = new ProgressPresenter(transport(calls), fakeClock())
    presenter.push([progress(1, "a")])
    await presenter.flush()
    presenter.push([end(1, "done"), progress(2, "b")])
    await presenter.flush()
    expect(calls).toEqual([
      { op: "send", id: 100n, text: "a" },
      { op: "edit", id: 100n, text: "done" },
      { op: "send", id: 101n, text: "b" },
    ])
    expect(presenter.messageIds()).toEqual([100n, 101n])
  })

  test("an end that arrives before the first send goes out supersedes it", async () => {
    const calls: Call[] = []
    const presenter = new ProgressPresenter(transport(calls), fakeClock())
    presenter.push([progress(1, "a"), end(1, "done")])
    await presenter.flush()
    expect(calls).toEqual([{ op: "send", id: 100n, text: "done" }])
  })

  test("a failed edit stops that message and reports once", async () => {
    const calls: Call[] = []
    const errors: string[] = []
    const presenter = new ProgressPresenter(transport(calls, { failEdits: true }), {
      ...fakeClock(),
      onError: (_error, op) => errors.push(op),
    })
    presenter.push([progress(1, "a")])
    await presenter.flush()
    presenter.push([progress(1, "b", true)])
    await presenter.flush()
    presenter.push([progress(1, "c", true), end(1, "end")])
    await presenter.flush()
    expect(calls.map((call) => call.text)).toEqual(["a"])
    expect(errors).toEqual(["edit"])
  })

  test("the final edit is retried once", async () => {
    const calls: Call[] = []
    let failures = 1
    const flaky: ProgressTransport = {
      async send(doc) {
        calls.push({ op: "send", id: 1n, text: doc.text })
        return 1n
      },
      async edit(id, doc) {
        if (doc.text === "end" && failures-- > 0) throw new Error("timeout")
        calls.push({ op: "edit", id, text: doc.text })
      },
    }
    const presenter = new ProgressPresenter(flaky, fakeClock())
    presenter.push([progress(1, "a")])
    await presenter.flush()
    presenter.push([end(1, "end")])
    await presenter.flush()
    expect(calls.map((call) => call.text)).toEqual(["a", "end"])
  })

  test("identical docs are not re-sent", async () => {
    const calls: Call[] = []
    const presenter = new ProgressPresenter(transport(calls), fakeClock())
    presenter.push([progress(1, "a")])
    await presenter.flush()
    presenter.push([progress(1, "a", true)])
    await presenter.flush()
    expect(calls).toHaveLength(1)
  })
})

describe("ProgressStream", () => {
  test("the end lands before flush resolves", async () => {
    const calls: Call[] = []
    const stream = new ProgressStream(transport(calls), fakeClock())
    stream.apply({ type: "turn.start" }, 0)
    stream.apply({ type: "item", id: "c1", body: { kind: "command", command: "ls" }, state: "done" }, 100)
    stream.apply({ type: "turn.end", outcome: "success" }, 2_000)
    await stream.flush()
    expect(calls[0]!.op).toBe("send")
    expect(calls.at(-1)!.text.startsWith("Worked for 2s")).toBe(true)
    expect(stream.isOpen).toBe(false)
  })
})
