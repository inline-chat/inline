import { describe, expect, test } from "bun:test"
import {
  TransferTraces,
  countTransferWork,
  recordSqlStatement,
  recordStorageOperation,
} from "./trace"

describe("transfer traces", () => {
  test("attributes nested work to every enclosing scope", async () => {
    const outer = await countTransferWork(async () => {
      recordSqlStatement()
      const inner = await countTransferWork(async () => {
        await Promise.resolve()
        recordSqlStatement()
        recordStorageOperation("put")
      })
      expect(inner.counters).toEqual({ sqlStatements: 1, storagePut: 1, storageGet: 0, storageDelete: 0 })
    })
    expect(outer.counters).toEqual({ sqlStatements: 2, storagePut: 1, storageGet: 0, storageDelete: 0 })
    // Outside any scope nothing is recorded and nothing throws.
    recordSqlStatement()
  })

  test("emits one identifier-free line per finished transfer with peak in-flight bytes", async () => {
    const lines: Record<string, unknown>[] = []
    let now = 0
    const traces = new TransferTraces((line) => { lines.push(line) }, () => now)
    const trace = traces.touch("upload:7", "upload", "v3")
    let releaseFirst!: () => void
    const first = traces.part("upload:7", trace, 100, async () => {
      recordSqlStatement()
      await new Promise<void>((resolve) => { releaseFirst = resolve })
    })
    const second = traces.part("upload:7", trace, 50, async () => { recordStorageOperation("get") })
    await second
    releaseFirst()
    await first
    trace.bytes = 150
    trace.parts = 2
    now = 42
    traces.finish("upload:7", "complete")
    traces.finish("upload:7", "complete")
    expect(lines).toEqual([{
      direction: "upload", carrier: "v3", bytes: 150, parts: 2, durationMs: 42, peakInFlightBytes: 150,
      sqlStatements: 1, storageOps: { put: 0, get: 1, delete: 0 }, retries: 0, outcome: "complete",
    }])
    expect(JSON.stringify(lines)).not.toContain("upload:7")
    expect(traces.openCount).toBe(0)
  })
})
