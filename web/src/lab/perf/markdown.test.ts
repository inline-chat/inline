import { describe, expect, it } from "vitest"
import { budgetById, budgetRow, infoRow } from "./budgets"
import { escapeCell, formatValue, rowNotes, toMarkdown } from "./markdown"

describe("formatting", () => {
  it("formats values by unit", () => {
    expect(formatValue(12.345, "ms")).toBe("12.3 ms")
    expect(formatValue(1.6, "frames")).toBe("2 frames")
    expect(formatValue(14_999, "elements")).toBe("14,999 elements")
    expect(formatValue(undefined, "ms")).toBe("–")
    expect(formatValue(Number.NaN, "KB")).toBe("–")
  })

  it("escapes pipes and flattens line breaks", () => {
    expect(escapeCell("a | b\n  c")).toBe("a \\| b c")
    expect(escapeCell("back\\slash")).toBe("back\\\\slash")
  })

  it("puts reasons, the caveat and the extras in the notes", () => {
    const row = budgetRow(
      "streaming",
      budgetById("stream-40"),
      {
        measure: "m",
        method: "x",
        input: "handle",
        samples: [6],
        upperBound: true,
        caveat: "Adjacent.",
        extras: [{ label: "frames over 32 ms", value: "0 of 180" }],
      },
      { allowed: true },
    )
    expect(rowNotes(row)).toBe("over the limit by an upper-bound measure; not conclusive. Adjacent.. frames over 32 ms 0 of 180")
  })
})

describe("the Markdown table", () => {
  it("has a title line, the warnings and one table row per result", () => {
    const rows = [
      budgetRow("send", budgetById("send"), { measure: "frame | index", method: "rAF", input: "synthetic", samples: [1, 1, 2] }, { allowed: true }),
      infoRow("warmStart", "warm-paint:shell", "Warm start: shell painted", "ms", {
        measure: "inline.boot.shell-paint",
        method: "measure",
        input: "reload",
        samples: [80, 90],
      }),
    ]
    const text = toMarkdown({ title: "Perf lab", run: "today, scale medium", warnings: ["CPU throttling unknown"], rows })
    const lines = text.split("\n")
    expect(lines[0]).toBe("**Perf lab**: today, scale medium")
    expect(lines[2]).toBe("- CPU throttling unknown")
    expect(lines[4]).toBe("| Moment | Measure | Method | Input | n | Median | Worst | Budget | Result | Notes |")
    expect(lines[6]).toBe(
      "| Send | frame \\| index | rAF | synthetic | 3 | 1 frames | 2 frames | row painted within one frame of the keypress | pass |  |",
    )
    expect(lines[7]).toBe("| Warm start: shell painted | inline.boot.shell-paint | measure | reload | 2 | 85 ms | 90 ms | – | info |  |")
    // Every table line has the same number of unescaped separators.
    const cells = (line: string) => line.replace(/\\\|/g, "").split("|").length
    expect(new Set(lines.slice(4).map(cells)).size).toBe(1)
  })

  it("leaves out the warnings block when there are none", () => {
    const lines = toMarkdown({ title: "T", run: "r", warnings: [], rows: [] }).split("\n")
    expect(lines).toEqual(["**T**: r", "", "| Moment | Measure | Method | Input | n | Median | Worst | Budget | Result | Notes |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"])
  })
})
