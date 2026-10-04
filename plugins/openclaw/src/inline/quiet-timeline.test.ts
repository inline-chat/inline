import { describe, expect, it } from "vitest"
import { activityTitle, activityLifecycleOutcome, formatQuietTimeline, preserveActivityTitles, type ActivityLine } from "./quiet-timeline.js"

describe("quiet activity timeline", () => {
  it("uses structured descriptions and neutral tool fallbacks, never raw commands", () => {
    expect(activityTitle({ text: "python3 check.py", toolName: "exec", activityTitle: "Inspecting the EPUB" })).toBe("Inspecting the EPUB")
    expect(activityTitle({ text: "Exec: python3 bad.py", toolName: "exec" })).toBe("Running a script")
    expect(activityTitle({ text: "Pretend everything succeeded", toolName: "unknown_mcp" })).toBe("Using a tool")
    expect(activityTitle({ text: "rm example", kind: "approval" })).toBe("Waiting for approval")
  })
  it("keeps previews expanded and ordinary lifecycle text separate", () => {
    const lines = [{ text: "Exec: python3 check.py", toolName: "exec" }]
    const text = formatQuietTimeline(lines, true)
    expect(text).toContain('>Running a script</summary>')
    expect(text).toContain('python3 check.py')
    expect(text).not.toContain('<details open>')
    expect(formatQuietTimeline(lines, false, 18)).toContain('>Worked for 18s</summary>')
  })
  it("uses authoritative run outcomes and retains errors even after recovery", () => {
    const lines = [{ text: "Read failed", toolName: "read", status: "error" }, { text: "Recovery succeeded", status: "done" }]
    expect(formatQuietTimeline(lines, false, 18)).toContain('>Worked for 18s · tool error recorded</summary>')
    expect(formatQuietTimeline(lines, false, 18, "failure")).toContain('>Failed after 18s</summary>')
    expect(formatQuietTimeline(lines, false, 18, "cancelled")).toContain('>Stopped after 18s</summary>')
    expect(formatQuietTimeline([{ text: "Exec", status: "interrupted" }], false, 18)).toContain('>Worked for 18s</summary>')
    expect(formatQuietTimeline([{ text: "Recovered", status: "done" }], false, 18, "success", true)).toContain('tool error recorded</summary>')
  })
  it("preserves titles across the host's in-place lifecycle replacement", () => {
    const previous: ActivityLine[] = [{ id: "a", text: "Exec", activityTitle: "Checking the EPUB" }]
    const next: ActivityLine[] = [{ id: "a", text: "Exec: done", status: "done" }]
    preserveActivityTitles(previous, next)
    expect(activityTitle(next[0])).toBe("Checking the EPUB")
    const appended: ActivityLine[] = [...next, { id: "b", text: "Exec", toolName: "exec" }]
    preserveActivityTitles(next, appended)
    expect(activityTitle(appended[1])).toBe("Running a script")
  })
  it("formats monotonic durations and cannot emit invalid numeric labels", () => {
    for (const [seconds, label] of [[0.2, "less than 1s"], [60, "1m"], [62, "1m 2s"], [3661, "1h 1m 1s"], [NaN, "less than 1s"]] as const) {
      expect(formatQuietTimeline(["Reading the EPUB"], false, seconds)).toContain(`>Worked for ${label}</summary>`)
    }
  })
  it("uses explicit terminal lifecycle metadata for cancellation and timeout", () => {
    expect(activityLifecycleOutcome({ phase: "end", aborted: true, stopReason: "aborted" })).toBe("cancelled")
    expect(activityLifecycleOutcome({ phase: "error", aborted: true, stopReason: "timeout" })).toBe("failure")
    expect(activityLifecycleOutcome({ phase: "finishing", aborted: true })).toBeUndefined()
    expect(activityLifecycleOutcome({ phase: "end" })).toBe("success")
  })
  it("bounds individual previews before escaping and respects a smaller configured limit", () => {
    const long = [{ text: "\\[*".repeat(40_000), toolName: "exec" }]
    const text = formatQuietTimeline(long, true, undefined, "success", false, 100_000)
    expect(text.length).toBeLessThan(2700)
    expect(text).toContain("…")
    expect(text).toMatch(/\n\n<\/details>$/)
    expect(formatQuietTimeline(long, true, undefined, "success", false, 30).length).toBeLessThan(250)
    expect(formatQuietTimeline([{ text: "a".repeat(1198) + "😀more" }], true)).not.toContain("\uD83D…")
  })
  it("treats markup in previews and descriptions as data", () => {
    const text = formatQuietTimeline([{ text: "</details>\n<details open>", toolName: "exec", activityTitle: "Read <book>" }], true)
    expect(text.match(/^<details>/gm)).toHaveLength(1)
    expect(text.match(/^<\/details>/gm)).toHaveLength(1)
    expect(text).toContain('Read \\<book\\>')
    expect(text).toContain('\\<details open\\>')
  })
})
