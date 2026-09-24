import { distribution, type Sample } from "./measure"

export type BenchmarkResult = {
  id: string
  version: number
  size: number
  rttMs: number
  maxCommands: number
  calibrationMs: number[]
  samples: Sample[]
}

export type BenchmarkReport = {
  schemaVersion: 1
  status: "passed"
  createdAt: string
  revision: { commit: string; dirty: boolean; sourceDigest: string }
  environment: {
    bun: string; postgres: string; postgresJs: string; drizzle: string
    platform: string; arch: string; cpu: string; poolMax: number
    clientPrepareDefault: boolean; concurrency: 1; cache: "cold-application-warm-pool"
  }
  warmup: number
  sampleCount: number
  results: BenchmarkResult[]
}

export function summarize(result: BenchmarkResult) {
  return {
    operationMs: distribution(result.samples.map((sample) => sample.operationMs)),
    settledMs: distribution(result.samples.map((sample) => sample.settledMs)),
    commands: distribution(result.samples.map((sample) => sample.sql.commands)),
    exchanges: distribution(result.samples.map((sample) => sample.wire?.exchangeBoundaries ?? NaN)),
    calibrationMs: distribution(result.calibrationMs),
  }
}

export function compareReports(before: BenchmarkReport, after: BenchmarkReport) {
  validateReport(before)
  validateReport(after)
  if (JSON.stringify(before.environment) !== JSON.stringify(after.environment) || before.warmup !== after.warmup || before.sampleCount !== after.sampleCount) {
    throw new Error("Incompatible benchmark environment, warmup, or sample count; rerun the baseline with matching settings")
  }
  const key = (result: BenchmarkResult) => `${result.id}@${result.rttMs}`
  const old = new Map(before.results.map((result) => [key(result), result]))
  if (old.size !== after.results.length) throw new Error("Benchmark scenario/RTT selections differ")
  return after.results.map((result) => {
    const previous = old.get(key(result))
    if (!previous || previous.version !== result.version || previous.size !== result.size) {
      throw new Error(`Incompatible scenario fixture: ${key(result)}`)
    }
    const a = summarize(previous), b = summarize(result)
    return {
      scenario: result.id, rttMs: result.rttMs,
      commandsSaved: a.commands.median - b.commands.median,
      exchangesSaved: a.exchanges.median - b.exchanges.median,
      operationMsSaved: a.operationMs.median - b.operationMs.median,
      settledMsSaved: a.settledMs.median - b.settledMs.median,
      calibrationBeforeMs: a.calibrationMs.median, calibrationAfterMs: b.calibrationMs.median,
    }
  })
}

export function validateReport(value: unknown): asserts value is BenchmarkReport {
  const report = value as BenchmarkReport | undefined
  if (!report || report.schemaVersion !== 1 || report.status !== "passed" || !report.environment ||
      !Array.isArray(report.results) || !report.results.length || !Number.isInteger(report.sampleCount) || report.sampleCount < 1 ||
      !Number.isInteger(report.warmup) || report.warmup < 1) {
    throw new Error("Not a completed backend benchmark report")
  }
  if (!report.revision || typeof report.revision.commit !== "string" || typeof report.revision.dirty !== "boolean" ||
      !/^[a-f0-9]{64}$/.test(report.revision.sourceDigest) || !Number.isFinite(Date.parse(report.createdAt)) ||
      ["bun", "postgres", "postgresJs", "drizzle", "platform", "arch", "cpu"].some((key) =>
        typeof report.environment[key as keyof BenchmarkReport["environment"]] !== "string") ||
      !Number.isInteger(report.environment.poolMax) || report.environment.poolMax < 1 ||
      typeof report.environment.clientPrepareDefault !== "boolean" || report.environment.concurrency !== 1 ||
      report.environment.cache !== "cold-application-warm-pool") {
    throw new Error("Missing benchmark provenance or measurement settings")
  }
  const keys = new Set<string>()
  for (const result of report.results) {
    const key = `${result.id}@${result.rttMs}`
    if (typeof result.id !== "string" || !Number.isInteger(result.version) || result.version < 1 ||
        !Number.isInteger(result.size) || result.size < 0 || !Number.isFinite(result.rttMs) || result.rttMs < 0 ||
        keys.has(key) || !Array.isArray(result.samples) || result.samples.length !== report.sampleCount) {
      throw new Error("Incomplete or duplicate backend benchmark samples")
    }
    keys.add(key)
    summarize(result)
  }
}
