/**
 * The budgets of `web/docs/performance.md` as data, and grading a row of
 * samples against one. Pure and DOM-free; tested in `budgets.test.ts`.
 *
 * A row is graded on a robust statistic (the median) unless the budget is a
 * ceiling on every sample ("no frame over 32 ms"), where the worst sample is
 * the statistic. Grades:
 *
 * - `pass` / `fail`: the statistic against the limit, and every check held;
 * - `inconclusive`: the method measures something adjacent (an upper bound
 *   that came out over, a scale the budget is not for, a spinner the lab
 *   cannot explain); the reasons say why;
 * - `not-measured`: no samples, an unsupported API, or frames throttled;
 * - `error`: the journey threw; the reason is its error;
 * - `info`: a number with no budget of its own.
 */

export type Unit = "ms" | "frames" | "tasks" | "mutations" | "rows" | "MB" | "elements" | "KB"

export type Grade = "pass" | "fail" | "inconclusive" | "not-measured" | "error" | "info"

/** How a journey drove the app: real input, a synthetic DOM event, a surface's handle, a reload, or nothing (passive). */
export type InputKind = "real" | "synthetic" | "handle" | "reload" | "passive"

export type Statistic = "median" | "max"

export type BudgetId =
  | "warm-paint"
  | "warm-live"
  | "switch-memory"
  | "switch-sqlite"
  | "send"
  | "typing-wait"
  | "typing-renders"
  | "incoming"
  | "stream-20"
  | "stream-40"
  | "stream-60"
  | "scroll"
  | "sidebar-scroll"
  | "sidebar-update"
  | "leader-handoff"
  | "memory-heap"
  | "memory-dom"
  | "initial-js"

export type Budget = {
  id: BudgetId
  /** The moment, in the words of `performance.md`. */
  moment: string
  /** The budget as written. */
  text: string
  limit: number
  unit: Unit
  /** `le`: at most the limit; `lt`: under it. */
  comparison: "le" | "lt"
  statistic: Statistic
  /** Graded only when animation frames run at full rate (the value depends on frames). */
  frameDependent: boolean
}

const budget = (b: Budget): Budget => b

export const BUDGETS: readonly Budget[] = [
  budget({
    id: "warm-paint",
    moment: "Warm start, first paint of sidebar and last chat",
    text: "150 ms (from the boot snapshot)",
    limit: 150,
    unit: "ms",
    comparison: "le",
    statistic: "median",
    frameDependent: true,
  }),
  budget({
    id: "warm-live",
    moment: "Warm start, core live and interactive",
    text: "500 ms",
    limit: 500,
    unit: "ms",
    comparison: "le",
    statistic: "median",
    frameDependent: true,
  }),
  budget({
    id: "switch-memory",
    moment: "Switch to a chat already in memory",
    text: "painted in the next frame",
    limit: 1,
    unit: "frames",
    comparison: "le",
    statistic: "median",
    frameDependent: true,
  }),
  budget({
    id: "switch-sqlite",
    moment: "Switch to a chat that is only in SQLite",
    text: "100 ms input to paint, no spinner",
    limit: 100,
    unit: "ms",
    comparison: "le",
    statistic: "median",
    frameDependent: true,
  }),
  budget({
    id: "send",
    moment: "Send",
    text: "row painted within one frame of the keypress",
    limit: 1,
    unit: "frames",
    comparison: "le",
    statistic: "median",
    frameDependent: true,
  }),
  budget({
    id: "typing-wait",
    moment: "Typing: no keystroke waits on store work",
    text: "no long task while typing",
    limit: 0,
    unit: "tasks",
    comparison: "le",
    statistic: "max",
    frameDependent: false,
  }),
  budget({
    id: "typing-renders",
    moment: "Typing: zero timeline renders",
    text: "0",
    limit: 0,
    unit: "mutations",
    comparison: "le",
    statistic: "max",
    frameDependent: false,
  }),
  budget({
    id: "incoming",
    moment: "Incoming message at the bottom",
    text: "painted within one frame of the patch (graded: 2 frames from the acknowledgement)",
    limit: 2,
    unit: "frames",
    comparison: "le",
    statistic: "median",
    frameDependent: true,
  }),
  ...([20, 40, 60] as const).map((rate) =>
    budget({
      id: `stream-${rate}`,
      moment: `Streaming message, ${rate} updates a second`,
      text: "only that row's block updates; under 4 ms of scripting per update",
      limit: 4,
      unit: "ms",
      comparison: "lt",
      statistic: "median",
      frameDependent: true,
    }),
  ),
  budget({
    id: "scroll",
    moment: "Scroll and history paging",
    text: "no frame over 32 ms",
    limit: 32,
    unit: "ms",
    comparison: "le",
    statistic: "max",
    frameDependent: true,
  }),
  budget({
    id: "sidebar-scroll",
    moment: "Sidebar at the large scale: scroll",
    text: "no frame over 32 ms; bounded rows in the DOM",
    limit: 32,
    unit: "ms",
    comparison: "le",
    statistic: "max",
    frameDependent: true,
  }),
  budget({
    id: "sidebar-update",
    moment: "Sidebar at the large scale: update one chat",
    text: "one row changes",
    limit: 1,
    unit: "rows",
    comparison: "le",
    statistic: "max",
    frameDependent: false,
  }),
  budget({
    id: "leader-handoff",
    moment: "Leader tab handoff",
    text: "1 s, with no lost or duplicated send",
    limit: 1000,
    unit: "ms",
    comparison: "le",
    statistic: "median",
    frameDependent: false,
  }),
  budget({
    id: "memory-heap",
    moment: "Memory: JS heap",
    text: "under 250 MB after a working day",
    limit: 250,
    unit: "MB",
    comparison: "lt",
    statistic: "max",
    frameDependent: false,
  }),
  budget({
    id: "memory-dom",
    moment: "Memory: DOM size",
    text: "under about 15,000 nodes",
    limit: 15_000,
    unit: "elements",
    comparison: "le",
    statistic: "max",
    frameDependent: false,
  }),
  budget({
    id: "initial-js",
    moment: "Initial UI JavaScript",
    text: "200 KB gzip",
    limit: 200,
    unit: "KB",
    comparison: "le",
    statistic: "max",
    frameDependent: false,
  }),
]

export const budgetById = (id: BudgetId): Budget => {
  const found = BUDGETS.find((b) => b.id === id)
  if (!found) throw new Error(`Unknown budget ${id}`)
  return found
}

/** The order rows appear in: the budget table's order, info rows after the budget they explain. */
export const rowOrder = (id: string): number => {
  const base = id.split(":")[0] as string
  const index = BUDGETS.findIndex((b) => b.id === base)
  return (index < 0 ? BUDGETS.length : index) * 100 + (id.includes(":") ? 1 : 0)
}

// ---------------------------------------------------------------------------
// Grading

export type Check = { ok: boolean; message: string }

export type FrameGrading = { allowed: boolean; reason?: string }

export type GradeInput = {
  samples: readonly number[]
  limit: number | undefined
  comparison: "le" | "lt"
  statistic: Statistic
  frameDependent: boolean
  frames: FrameGrading
  /** The method gives an upper bound: over the limit is inconclusive, not a failure. */
  upperBound?: boolean
  checks?: readonly Check[]
  /** Reasons the value cannot be trusted to pass (it still fails when over). */
  inconclusive?: readonly string[]
  /** The row was not measured, and why (an unsupported API, for example). */
  notMeasured?: string
}

export type GradeResult = { grade: Grade; value: number | undefined; reasons: string[] }

export const statisticOf = (samples: readonly number[], statistic: Statistic): number | undefined => {
  if (samples.length === 0) return undefined
  if (statistic === "max") return samples.reduce((a, b) => (b > a ? b : a))
  const sorted = [...samples].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1
    ? (sorted[middle] as number)
    : ((sorted[middle - 1] as number) + (sorted[middle] as number)) / 2
}

export const within = (value: number, limit: number, comparison: "le" | "lt"): boolean =>
  comparison === "le" ? value <= limit : value < limit

export const grade = (input: GradeInput): GradeResult => {
  if (input.notMeasured !== undefined) return { grade: "not-measured", value: undefined, reasons: [input.notMeasured] }
  const value = statisticOf(input.samples, input.statistic)
  if (value === undefined) return { grade: "not-measured", value, reasons: ["no samples"] }
  if (input.frameDependent && !input.frames.allowed) {
    return { grade: "not-measured", value, reasons: [input.frames.reason ?? "frames throttled"] }
  }
  const failed = (input.checks ?? []).filter((check) => !check.ok).map((check) => check.message)
  if (failed.length > 0) return { grade: "fail", value, reasons: failed }
  if (input.limit === undefined) return { grade: "info", value, reasons: [] }
  if (!within(value, input.limit, input.comparison)) {
    if (input.upperBound) {
      return { grade: "inconclusive", value, reasons: ["over the limit by an upper-bound measure; not conclusive"] }
    }
    return { grade: "fail", value, reasons: [`${input.statistic} over the limit`] }
  }
  const doubts = [...(input.inconclusive ?? [])]
  if (doubts.length > 0) return { grade: "inconclusive", value, reasons: doubts }
  return { grade: "pass", value, reasons: [] }
}

// ---------------------------------------------------------------------------
// Rows

export type Extra = { label: string; value: string }

export type ResultRow = {
  /** A budget ID, or `<budget>:<detail>` for an info row under it. */
  id: string
  journey: string
  moment: string
  /** What was measured. */
  measure: string
  /** How, in a phrase; the README has the long form. */
  method: string
  input: InputKind
  unit: Unit
  samples: number[]
  n: number
  median: number | undefined
  worst: number | undefined
  statistic: Statistic
  /** The graded value (the statistic). */
  value: number | undefined
  budget: string
  grade: Grade
  reasons: string[]
  caveat?: string
  extras: Extra[]
}

export type Measurement = {
  measure: string
  method: string
  input: InputKind
  samples: readonly number[]
  caveat?: string
  extras?: readonly Extra[]
  checks?: readonly Check[]
  upperBound?: boolean
  inconclusive?: readonly string[]
  notMeasured?: string
}

const middleOf = (samples: readonly number[]) => statisticOf(samples, "median")
const worstOf = (samples: readonly number[]) => statisticOf(samples, "max")

/** A graded row for one budget. */
export const budgetRow = (journey: string, b: Budget, m: Measurement, frames: FrameGrading): ResultRow => {
  const result = grade({
    samples: m.samples,
    limit: b.limit,
    comparison: b.comparison,
    statistic: b.statistic,
    frameDependent: b.frameDependent,
    frames,
    ...(m.upperBound !== undefined ? { upperBound: m.upperBound } : {}),
    ...(m.checks ? { checks: m.checks } : {}),
    ...(m.inconclusive ? { inconclusive: m.inconclusive } : {}),
    ...(m.notMeasured !== undefined ? { notMeasured: m.notMeasured } : {}),
  })
  return {
    id: b.id,
    journey,
    moment: b.moment,
    measure: m.measure,
    method: m.method,
    input: m.input,
    unit: b.unit,
    samples: [...m.samples],
    n: m.samples.length,
    median: middleOf(m.samples),
    worst: worstOf(m.samples),
    statistic: b.statistic,
    value: result.value,
    budget: b.text,
    grade: result.grade,
    reasons: result.reasons,
    ...(m.caveat !== undefined ? { caveat: m.caveat } : {}),
    extras: [...(m.extras ?? [])],
  }
}

/** A row with no budget of its own (a boot mark under the warm start, for example). */
export const infoRow = (
  journey: string,
  id: string,
  moment: string,
  unit: Unit,
  m: Omit<Measurement, "checks" | "upperBound" | "inconclusive">,
): ResultRow => ({
  id,
  journey,
  moment,
  measure: m.measure,
  method: m.method,
  input: m.input,
  unit,
  samples: [...m.samples],
  n: m.samples.length,
  median: middleOf(m.samples),
  worst: worstOf(m.samples),
  statistic: "median",
  value: middleOf(m.samples),
  budget: "",
  grade: m.notMeasured !== undefined ? "not-measured" : m.samples.length === 0 ? "not-measured" : "info",
  reasons: m.notMeasured !== undefined ? [m.notMeasured] : m.samples.length === 0 ? ["no samples"] : [],
  ...(m.caveat !== undefined ? { caveat: m.caveat } : {}),
  extras: [...(m.extras ?? [])],
})

/** Rows for budgets whose journey threw, so the table stays complete. */
export const errorRows = (journey: string, ids: readonly BudgetId[], error: unknown): ResultRow[] => {
  const message = error instanceof Error ? error.message : String(error)
  return ids.map((id) => {
    const b = budgetById(id)
    return {
      id,
      journey,
      moment: b.moment,
      measure: "",
      method: "",
      input: "passive" as const,
      unit: b.unit,
      samples: [],
      n: 0,
      median: undefined,
      worst: undefined,
      statistic: b.statistic,
      value: undefined,
      budget: b.text,
      grade: "error" as const,
      reasons: [message],
      extras: [],
    }
  })
}

/** Replace rows with the same ID, keep the rest, and order by the budget table. */
export const mergeRows = (current: readonly ResultRow[], next: readonly ResultRow[]): ResultRow[] => {
  const ids = new Set(next.map((row) => row.id))
  return [...current.filter((row) => !ids.has(row.id)), ...next].sort((a, b) => rowOrder(a.id) - rowOrder(b.id))
}

export const gradeCounts = (rows: readonly ResultRow[]): Record<Grade, number> => {
  const counts: Record<Grade, number> = { pass: 0, fail: 0, inconclusive: 0, "not-measured": 0, error: 0, info: 0 }
  for (const row of rows) counts[row.grade] += 1
  return counts
}
