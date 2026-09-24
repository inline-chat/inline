import { expect, test } from "bun:test"
import { resolve } from "node:path"
import { createTestEnvironment } from "./test-environment"
import { compareReports, validateReport, type BenchmarkReport } from "../src/__tests__/performance/report"

const root = resolve(import.meta.dir, "..")
const run = async (...args: string[]) => {
  const child = Bun.spawn({
    cmd: [process.execPath, "--no-env-file", "scripts/benchmark-backend.ts", ...args],
    cwd: root, env: createTestEnvironment(process.env), stdout: "pipe", stderr: "pipe",
  })
  const [code, out, error] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
  return { code, output: out + error }
}

test("benchmark inventory is available without a database", async () => {
  const result = await run("--list")
  expect(result.code).toBe(0)
  expect(result.output).toContain("send.public.100")
})

test.each([
  ["--scenario", "typo", "Unknown backend scenario"],
  ["--samples", "0", "--samples must"],
  ["--warmup", "NaN", "--warmup must"],
  ["--rtt", "0,,3", "Empty RTT"],
  ["--rtt", "-1", "RTT must"],
  ["--output", ".env.json", "never environment files"],
  ["--retry", "3", "Unknown option"],
])("invalid %s %s fails before provisioning: %s", async (flag, value, message) => {
  const result = await run(`${flag}=${value}`)
  expect(result.code).not.toBe(0)
  expect(result.output).toContain(message)
})

function report(): BenchmarkReport {
  return {
    schemaVersion: 1, status: "passed", createdAt: "2026-01-01T00:00:00.000Z", revision: { commit: "fixture", dirty: false, sourceDigest: "a".repeat(64) },
    environment: { bun: "1.4.0", postgres: "15", postgresJs: "3.4.7", drizzle: "fixture", platform: "darwin", arch: "arm64", cpu: "fixture", poolMax: 10, clientPrepareDefault: true, concurrency: 1, cache: "cold-application-warm-pool" },
    warmup: 1, sampleCount: 1,
    results: [{ id: "send.dm.open", version: 1, size: 1, rttMs: 3, maxCommands: 27, calibrationMs: [3], samples: [{
      operationMs: 10, settledMs: 12, commandsBeforeReturn: 2,
      sql: { commands: 3, catalogCommands: 0, connections: 1, transactions: 0, shapes: {} },
      wire: { exchangeBoundaries: 6, frames: {}, clientBytes: 100, serverBytes: 100 },
    }] }],
  }
}

test("comparisons report saved work and elapsed time independently", () => {
  const before = report(), after = report()
  after.results[0]!.samples[0]!.sql.commands = 2
  after.results[0]!.samples[0]!.wire!.exchangeBoundaries = 4
  after.results[0]!.samples[0]!.operationMs = 7
  expect(compareReports(before, after)[0]).toMatchObject({ commandsSaved: 1, exchangesSaved: 2, operationMsSaved: 3 })
})

test("failed, empty, incomplete and incompatible runs cannot be compared as successful evidence", () => {
  expect(() => validateReport({ ...report(), status: "failed" })).toThrow()
  expect(() => validateReport({ ...report(), status: "candidate" })).toThrow()
  expect(() => validateReport({ ...report(), environment: {} })).toThrow()
  expect(() => validateReport({ ...report(), results: [] })).toThrow()
  expect(() => validateReport({ ...report(), sampleCount: 2 })).toThrow()
  for (const mutate of [
    (r: BenchmarkReport) => { r.environment.bun = "different" },
    (r: BenchmarkReport) => { r.results[0]!.version++ },
    (r: BenchmarkReport) => { r.results[0]!.rttMs++ },
    (r: BenchmarkReport) => { r.results[0]!.size++ },
    (r: BenchmarkReport) => { r.warmup++ },
    (r: BenchmarkReport) => { r.results.push(structuredClone(r.results[0]!)) },
  ]) {
    const changed = report()
    mutate(changed)
    expect(() => compareReports(report(), changed)).toThrow()
  }
})
