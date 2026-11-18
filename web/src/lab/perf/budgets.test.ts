import { describe, expect, it } from "vitest"
import { BUDGETS, budgetById, budgetRow, errorRows, grade, gradeCounts, infoRow, mergeRows, statisticOf, type GradeInput } from "./budgets"

const base: GradeInput = {
  samples: [10, 20, 30],
  limit: 25,
  comparison: "le",
  statistic: "median",
  frameDependent: false,
  frames: { allowed: true },
}

describe("budget table", () => {
  it("has one row per budget of performance.md, with unique IDs", () => {
    const ids = BUDGETS.map((b) => b.id)
    expect(new Set(ids).size).toBe(ids.length)
    expect(ids).toEqual([
      "warm-paint",
      "warm-live",
      "switch-memory",
      "switch-sqlite",
      "send",
      "typing-wait",
      "typing-renders",
      "incoming",
      "stream-20",
      "stream-40",
      "stream-60",
      "scroll",
      "sidebar-scroll",
      "sidebar-update",
      "leader-handoff",
      "memory-heap",
      "memory-dom",
      "initial-js",
    ])
    expect(budgetById("warm-paint").limit).toBe(150)
    expect(budgetById("switch-sqlite").limit).toBe(100)
    expect(budgetById("stream-60").comparison).toBe("lt")
    expect(() => budgetById("nope" as never)).toThrow()
  })
})

describe("grading", () => {
  it("grades the median against the limit", () => {
    expect(grade(base)).toEqual({ grade: "pass", value: 20, reasons: [] })
    expect(grade({ ...base, limit: 15 }).grade).toBe("fail")
  })

  it("grades the worst sample for ceilings", () => {
    expect(statisticOf([10, 40, 20], "max")).toBe(40)
    expect(grade({ ...base, statistic: "max", limit: 32 }).grade).toBe("pass")
    expect(grade({ ...base, samples: [10, 33], statistic: "max", limit: 32 }).grade).toBe("fail")
  })

  it("distinguishes at most from under", () => {
    expect(grade({ ...base, samples: [4], limit: 4, comparison: "le" }).grade).toBe("pass")
    expect(grade({ ...base, samples: [4], limit: 4, comparison: "lt" }).grade).toBe("fail")
  })

  it("does not grade frame-time rows when frames are throttled", () => {
    const result = grade({ ...base, frameDependent: true, frames: { allowed: false, reason: "not measured: frames throttled" } })
    expect(result.grade).toBe("not-measured")
    expect(result.reasons).toEqual(["not measured: frames throttled"])
    expect(grade({ ...base, frameDependent: false, frames: { allowed: false } }).grade).toBe("pass")
  })

  it("reports no samples and explicit not-measured reasons", () => {
    expect(grade({ ...base, samples: [] })).toEqual({ grade: "not-measured", value: undefined, reasons: ["no samples"] })
    expect(grade({ ...base, notMeasured: "unsupported" }).reasons).toEqual(["unsupported"])
  })

  it("fails on a failed check whatever the value", () => {
    const result = grade({ ...base, checks: [{ ok: true, message: "fine" }, { ok: false, message: "3 mutations outside" }] })
    expect(result).toEqual({ grade: "fail", value: 20, reasons: ["3 mutations outside"] })
  })

  it("calls an upper bound over the limit inconclusive, not a failure", () => {
    expect(grade({ ...base, limit: 15, upperBound: true }).grade).toBe("inconclusive")
    expect(grade({ ...base, upperBound: true }).grade).toBe("pass")
  })

  it("keeps doubts from turning a value within the limit into a pass, but not a failure into one", () => {
    expect(grade({ ...base, inconclusive: ["scale"] })).toEqual({ grade: "inconclusive", value: 20, reasons: ["scale"] })
    expect(grade({ ...base, limit: 15, inconclusive: ["scale"] }).grade).toBe("fail")
  })
})

describe("rows", () => {
  it("builds a row with its median, worst and grade", () => {
    const row = budgetRow("send", budgetById("send"), { measure: "m", method: "x", input: "synthetic", samples: [1, 1, 2] }, { allowed: true })
    expect(row).toMatchObject({ id: "send", n: 3, median: 1, worst: 2, value: 1, grade: "pass", unit: "frames" })
  })

  it("marks info rows and their missing samples", () => {
    expect(infoRow("warmStart", "warm-paint:shell", "Shell", "ms", { measure: "", method: "", input: "reload", samples: [5] }).grade).toBe("info")
    expect(infoRow("warmStart", "warm-paint:snapshot", "Snapshot", "ms", { measure: "", method: "", input: "reload", samples: [] }).grade).toBe(
      "not-measured",
    )
  })

  it("fills a failed journey's rows with its error", () => {
    const rows = errorRows("typing", ["typing-wait", "typing-renders"], new Error("no composer"))
    expect(rows.map((row) => [row.id, row.grade, row.reasons[0]])).toEqual([
      ["typing-wait", "error", "no composer"],
      ["typing-renders", "error", "no composer"],
    ])
  })

  it("merges a rerun's rows in place and keeps the budget order", () => {
    const make = (id: "send" | "warm-paint" | "memory-dom", samples: number[]) =>
      budgetRow("x", budgetById(id), { measure: "", method: "", input: "passive", samples }, { allowed: true })
    const info = infoRow("warmStart", "warm-paint:shell", "Shell", "ms", { measure: "", method: "", input: "reload", samples: [1] })
    const merged = mergeRows([make("memory-dom", [1]), make("send", [3])], [make("send", [1]), info, make("warm-paint", [200])])
    expect(merged.map((row) => [row.id, row.median])).toEqual([
      ["warm-paint", 200],
      ["warm-paint:shell", 1],
      ["send", 1],
      ["memory-dom", 1],
    ])
    expect(gradeCounts(merged)).toMatchObject({ pass: 2, fail: 1, info: 1 })
  })
})
