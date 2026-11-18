/**
 * The result table as Markdown, ready to paste into the progress log, and
 * the number formatting the page shares. Pure; tested in `markdown.test.ts`.
 */

import type { Grade, ResultRow, Unit } from "./budgets"

const DIGITS: Record<Unit, number> = {
  ms: 1,
  frames: 0,
  tasks: 0,
  mutations: 0,
  rows: 0,
  MB: 1,
  elements: 0,
  KB: 1,
}

export const formatValue = (value: number | undefined, unit: Unit): string => {
  if (value === undefined || !Number.isFinite(value)) return "–"
  const digits = DIGITS[unit]
  const rounded = Math.round(value * 10 ** digits) / 10 ** digits
  return `${rounded.toLocaleString("en-US", { maximumFractionDigits: digits })} ${unit}`
}

export const gradeLabel = (grade: Grade): string =>
  ({
    pass: "pass",
    fail: "FAIL",
    inconclusive: "inconclusive",
    "not-measured": "not measured",
    error: "ERROR",
    info: "info",
  })[grade]

/** A cell's text with pipes escaped and line breaks flattened. */
export const escapeCell = (text: string): string => text.replace(/\\/g, "\\\\").replace(/\|/g, "\\|").replace(/\s*\n\s*/g, " ").trim()

/** The notes cell: why it did not pass, then the caveat, then the extras. */
export const rowNotes = (row: ResultRow): string => {
  const parts: string[] = []
  if (row.reasons.length > 0) parts.push(row.reasons.join("; "))
  if (row.caveat) parts.push(row.caveat)
  if (row.extras.length > 0) parts.push(row.extras.map((extra) => `${extra.label} ${extra.value}`).join(", "))
  return parts.join(". ")
}

export const toMarkdown = (input: { title: string; run: string; warnings: readonly string[]; rows: readonly ResultRow[] }): string => {
  const lines: string[] = [`**${escapeCell(input.title)}**: ${escapeCell(input.run)}`, ""]
  if (input.warnings.length > 0) {
    for (const warning of input.warnings) lines.push(`- ${escapeCell(warning)}`)
    lines.push("")
  }
  lines.push("| Moment | Measure | Method | Input | n | Median | Worst | Budget | Result | Notes |")
  lines.push("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
  for (const row of input.rows) {
    lines.push(
      `| ${[
        row.moment,
        row.measure,
        row.method,
        row.input,
        String(row.n),
        formatValue(row.median, row.unit),
        formatValue(row.worst, row.unit),
        row.budget || "–",
        gradeLabel(row.grade),
        rowNotes(row),
      ]
        .map(escapeCell)
        .join(" | ")} |`,
    )
  }
  return lines.join("\n")
}
