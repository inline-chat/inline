/**
 * Result rows of the timeline lab, as plain data. Pure; tested in
 * `results.test.ts`. The budget is `web/docs/performance.md`'s: under 1 px
 * after any single operation, and nothing that accumulates over repeated
 * ones.
 */

import type { TimelineMode } from "@inline/timeline"

export const DRIFT_BUDGET_PX = 1

/**
 * What a row's drift is measured against:
 * - `anchor`: the controller's reference row's offset from the container's top, before and after;
 * - `bottom`: the distance from the bottom while following latest (must stay 0);
 * - `landing`: after a jump, the offset's distance from the one that centers the target (or the bottom, for latest);
 * - `line`: after an unread open, the unread line's distance from the uncovered top;
 * - `none`: a behavior check without a geometric measure.
 */
export type Metric = "anchor" | "bottom" | "landing" | "line" | "none"

/** One repetition: its drift after the operation settled (signed), and the largest seen in any frame on the way. */
export type RepMeasure = { final: number; maxAbs: number }

export type Renders = {
  /** Renders of the timeline's list component (it reads keys). */
  list: number
  /** Renders of the timeline's row wrappers. */
  rows: number
  /** Renders of the lab's own row content. */
  labRows: number
}

export type Check = { ok: boolean; message: string }

export type OpResult = {
  operation: string
  metric: Metric
  repetitions: number
  /** Largest absolute drift in any sampled frame of any repetition, px. */
  maxAbsDrift: number
  /** Sum of the repetitions' final signed drifts, px: what a reader would see after all of them. */
  accumulatedDrift: number
  renders: Renders
  modeBefore: TimelineMode
  modeAfter: TimelineMode
  pass: boolean
  /** Why it failed, when it did. */
  failures: string[]
  /** Facts worth reading next to the numbers (rows trimmed, spinner seen, ...). */
  notes: string[]
  /** Wall-clock duration of the operation, ms. */
  ms: number
}

export type SummaryInput = {
  operation: string
  metric: Metric
  reps: readonly RepMeasure[]
  renders: Renders
  modeBefore: TimelineMode
  modeAfter: TimelineMode
  checks?: readonly Check[]
  notes?: readonly string[]
  ms: number
}

const round = (value: number) => Math.round(value * 1000) / 1000

export const summarize = (input: SummaryInput): OpResult => {
  let maxAbs = 0
  let accumulated = 0
  for (const rep of input.reps) {
    maxAbs = Math.max(maxAbs, rep.maxAbs, Math.abs(rep.final))
    accumulated += rep.final
  }
  const failures: string[] = []
  if (input.metric !== "none") {
    if (!(maxAbs < DRIFT_BUDGET_PX)) failures.push(`max drift ${round(maxAbs)} px ≥ ${DRIFT_BUDGET_PX} px`)
    if (!(Math.abs(accumulated) < DRIFT_BUDGET_PX))
      failures.push(`accumulated drift ${round(accumulated)} px ≥ ${DRIFT_BUDGET_PX} px`)
  }
  for (const check of input.checks ?? []) if (!check.ok) failures.push(check.message)
  return {
    operation: input.operation,
    metric: input.metric,
    repetitions: input.reps.length,
    maxAbsDrift: round(maxAbs),
    accumulatedDrift: round(accumulated),
    renders: input.renders,
    modeBefore: input.modeBefore,
    modeAfter: input.modeAfter,
    pass: failures.length === 0,
    failures,
    notes: [...(input.notes ?? [])],
    ms: Math.round(input.ms),
  }
}

/** A failed operation (it threw): recorded as a row so a run-all table is always complete. */
export const failedResult = (operation: string, error: unknown, mode: TimelineMode, ms: number): OpResult => ({
  operation,
  metric: "none",
  repetitions: 0,
  maxAbsDrift: 0,
  accumulatedDrift: 0,
  renders: { list: 0, rows: 0, labRows: 0 },
  modeBefore: mode,
  modeAfter: mode,
  pass: false,
  failures: [error instanceof Error ? error.message : String(error)],
  notes: [],
  ms: Math.round(ms),
})

/** The whole table as tab-separated text, for pasting into a report. */
export const resultsAsText = (results: readonly OpResult[]): string => {
  const header = ["operation", "metric", "reps", "max |drift| px", "accumulated px", "list", "rows", "lab rows", "mode", "result"]
  const lines = results.map((r) =>
    [
      r.operation,
      r.metric,
      r.repetitions,
      r.maxAbsDrift,
      r.accumulatedDrift,
      r.renders.list,
      r.renders.rows,
      r.renders.labRows,
      `${r.modeBefore} → ${r.modeAfter}`,
      r.pass ? "pass" : `FAIL: ${r.failures.join("; ")}`,
    ].join("\t"),
  )
  return [header.join("\t"), ...lines].join("\n")
}
