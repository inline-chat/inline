import { describe, expect, it } from "vitest"
import { failedResult, resultsAsText, summarize, type SummaryInput } from "./results"

const base: SummaryInput = {
  operation: "prepend",
  metric: "anchor",
  reps: [],
  renders: { list: 1, rows: 20, labRows: 20 },
  modeBefore: "reading",
  modeAfter: "reading",
  ms: 10.4,
}

describe("summarize", () => {
  it("passes under 1 px per operation with nothing accumulating", () => {
    const result = summarize({ ...base, reps: [{ final: 0.3, maxAbs: 0.4 }, { final: -0.3, maxAbs: 0.3 }] })
    expect(result.pass).toBe(true)
    expect(result.maxAbsDrift).toBe(0.4)
    expect(result.accumulatedDrift).toBe(0)
    expect(result.repetitions).toBe(2)
    expect(result.ms).toBe(10)
  })

  it("fails on one frame at or over 1 px, even when the final position is right", () => {
    const result = summarize({ ...base, reps: [{ final: 0, maxAbs: 1 }] })
    expect(result.pass).toBe(false)
    expect(result.failures[0]).toMatch(/max drift 1 px/)
  })

  it("fails when small drifts accumulate", () => {
    const reps = Array.from({ length: 100 }, () => ({ final: 0.02, maxAbs: 0.02 }))
    const result = summarize({ ...base, reps })
    expect(result.maxAbsDrift).toBe(0.02)
    expect(result.accumulatedDrift).toBe(2)
    expect(result.pass).toBe(false)
    expect(result.failures).toEqual(["accumulated drift 2 px ≥ 1 px"])
  })

  it("fails on a failed check and ignores drift for behavior-only rows", () => {
    const checked = summarize({ ...base, checks: [{ ok: false, message: "mode did not stay reading" }] })
    expect(checked.pass).toBe(false)
    expect(checked.failures).toEqual(["mode did not stay reading"])
    const behavior = summarize({ ...base, metric: "none", reps: [{ final: 5, maxAbs: 5 }] })
    expect(behavior.pass).toBe(true)
  })
})

describe("failedResult and resultsAsText", () => {
  it("records a thrown operation as a failing row and prints a table", () => {
    const failed = failedResult("jump far", new Error("frames stopped"), "reading", 3)
    expect(failed.pass).toBe(false)
    const text = resultsAsText([summarize({ ...base, reps: [{ final: 0, maxAbs: 0 }] }), failed])
    const lines = text.split("\n")
    expect(lines).toHaveLength(3)
    expect(lines[1]).toContain("pass")
    expect(lines[2]).toContain("FAIL: frames stopped")
  })
})
