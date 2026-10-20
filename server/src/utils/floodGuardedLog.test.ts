import { describe, expect, test } from "bun:test"
import { createFloodGuardedLog } from "./floodGuardedLog"

describe("createFloodGuardedLog", () => {
  test("writes a lone line right away", () => {
    const lines: [string, Record<string, unknown>][] = []
    const write = createFloodGuardedLog({ write: (message, fields) => lines.push([message, fields]), summary: "suppressed" })

    write("anomaly", { userId: 7 }, 1_000_000)

    expect(lines).toEqual([["anomaly", { userId: 7 }]])
  })

  test("caps a flood per window and reports the suppressed count once", () => {
    const lines: string[] = []
    const scheduled: { flush: () => void; delayMs: number }[] = []
    const write = createFloodGuardedLog({
      write: (message, fields) => lines.push(message === "suppressed" ? `suppressed ${fields["suppressed"]}` : message),
      summary: "suppressed",
      schedule: (flush, delayMs) => scheduled.push({ flush, delayMs }),
      limit: 3,
      windowMs: 60_000,
    })

    for (let index = 0; index < 8; index += 1) write("line", {}, 1_000_000 + index * 1_000)
    expect(lines).toEqual(["line", "line", "line"])
    expect(scheduled).toHaveLength(1)
    expect(scheduled[0]?.delayMs).toBe(57_000)

    scheduled[0]?.flush()
    expect(lines).toEqual(["line", "line", "line", "suppressed 5"])

    write("line", {}, 1_061_000)
    expect(lines.at(-1)).toBe("line")
  })

  test("reports a pending suppressed count before a later window's first line", () => {
    const lines: string[] = []
    const write = createFloodGuardedLog({
      write: (message, fields) => lines.push(message === "suppressed" ? `suppressed ${fields["suppressed"]}` : message),
      summary: "suppressed",
      schedule: () => {},
      limit: 1,
      windowMs: 60_000,
    })

    write("line", {}, 0)
    write("line", {}, 1_000)
    write("next", {}, 60_000)

    expect(lines).toEqual(["line", "suppressed 1", "next"])
  })
})
