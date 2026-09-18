import { describe, expect, it } from "bun:test"
import { parseContentBackfillOptions } from "./encrypt-content"

describe("content backfill command arguments", () => {
  it("defaults to bounded verification", () => {
    expect(parseContentBackfillOptions(["--database", "synthetic"])).toEqual({
      apply: false, database: "synthetic", batchSize: 100, maxMinutes: 20,
    })
    expect(parseContentBackfillOptions(["--database", "synthetic", "--apply", "--backup-verified", "--readers-ready"]).apply).toBe(true)
  })
  it("requires explicit target and acknowledgements and rejects ambiguous or unbounded arguments", () => {
    for (const args of [[], ["--database"], ["--database", "test", "--apply"],
      ["--database", "test", "--apply", "--readers-ready"], ["--database", "test", "--all"],
      ["--database", "test", "--batch-size", "501"], ["--database", "test", "--max-minutes", "0"],
      ["--database", "test", "--database", "other"]]) {
      expect(() => parseContentBackfillOptions(args)).toThrow()
    }
  })
})
