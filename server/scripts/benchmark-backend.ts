import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs"
import { dirname, basename, resolve } from "node:path"
import { parseArgs } from "node:util"
import { defaultScenarios, scenarios, selectScenarios } from "../src/__tests__/performance/catalog"
import { compareReports, validateReport, type BenchmarkReport } from "../src/__tests__/performance/report"
import { createTestEnvironment } from "./test-environment"
import { assertLocalTestDatabaseUrl, prepareTestDatabaseTemplate } from "./test-database-template"

const root = resolve(import.meta.dir, "..")
const { values } = parseArgs({
  args: process.argv.slice(2), strict: true, allowPositionals: false,
  options: {
    scenario: { type: "string", multiple: true }, all: { type: "boolean" }, list: { type: "boolean" },
    samples: { type: "string" }, warmup: { type: "string" }, rtt: { type: "string" },
    output: { type: "string" }, compare: { type: "string" }, help: { type: "boolean", short: "h" },
  },
})
if (values.help) {
  console.info(`Usage: bun run bench:backend [--scenario ID ... | --all] [--rtt 0,3,5]
  --list             List scenarios and reviewed SQL command budgets; no DB needed
  --samples N        Measured, independently verified iterations (default 20, max 200)
  --warmup N         Unreported, verified iterations per case (default 3, max 20)
  --rtt MS,...       Requested additional loopback transport RTT (default 0, max 50)
  --output FILE.json Save a new report; never overwrite a baseline
  --compare FILE.json Compare a completed, compatible baseline with this run

Defaults: ${defaultScenarios.join(", ")}.
Requires local TEST_DATABASE_URL with CREATEDB, as test:postgres does.
Fixtures and verification are outside timing; wall-clock results are not CI gates.
See BENCHMARKING.md for measurement boundaries and interpretation.`)
  process.exit(0)
}
if (values.list) {
  for (const scenario of scenarios) console.info(`${scenario.id.padEnd(26)} <= ${scenario.maxCommands} SQL commands`)
  process.exit(0)
}
if (values.all && values.scenario) throw new Error("Choose --all or --scenario")
const selected = selectScenarios(values.all ? scenarios.map((scenario) => scenario.id) : values.scenario ?? defaultScenarios)
const integer = (input: string | undefined, fallback: number, maximum: number, label: string) => {
  const number = input === undefined ? fallback : Number(input)
  if (!Number.isInteger(number) || number < 1 || number > maximum) throw new Error(`${label} must be between 1 and ${maximum}`)
  return number
}
const samples = integer(values.samples, 20, 200, "--samples")
const warmup = integer(values.warmup, 3, 20, "--warmup")
const rtts = [...new Set((values.rtt ?? "0").split(",").map((value) => {
  if (!value.trim()) throw new Error("Empty RTT value")
  const ms = Number(value)
  if (!Number.isFinite(ms) || ms < 0 || ms > 50) throw new Error("RTT must be between 0 and 50 ms")
  return ms
}))]
const reportPath = (path: string) => {
  if (!path.endsWith(".json") || basename(path).startsWith(".env")) throw new Error("Reports must be .json files, never environment files")
  return resolve(root, path)
}
const directory = resolve(root, ".test-results", `backend-${Date.now()}-${process.pid}`)
const output = reportPath(values.output ?? resolve(directory, "report.json"))
if (existsSync(output)) throw new Error("Output already exists; choose a new report path to preserve the baseline")
const baseline: unknown = values.compare ? JSON.parse(readFileSync(reportPath(values.compare), "utf8")) : undefined
if (baseline !== undefined) validateReport(baseline)
const databaseUrl = process.env["TEST_DATABASE_URL"] ?? process.env["DATABASE_URL"]
if (!databaseUrl) throw new Error("Set a local TEST_DATABASE_URL with CREATEDB before benchmarking")
assertLocalTestDatabaseUrl(databaseUrl)
mkdirSync(directory, { recursive: true })
const candidate = resolve(directory, "worker.json")
const environment = createTestEnvironment(process.env, databaseUrl)
environment["INLINE_BACKEND_BENCH_CONFIG"] = JSON.stringify({ ids: selected.map((scenario) => scenario.id), samples, warmup, rtts, output: candidate })

let template: Awaited<ReturnType<typeof prepareTestDatabaseTemplate>> | undefined
let child: ReturnType<typeof Bun.spawn> | undefined
let completed: BenchmarkReport | undefined
let interrupted = 0
const interrupt = () => { interrupted = 130; child?.kill("SIGINT") }
const terminate = () => { interrupted = 143; child?.kill("SIGTERM") }
process.on("SIGINT", interrupt)
process.on("SIGTERM", terminate)
try {
  template = await prepareTestDatabaseTemplate(databaseUrl)
  environment["INLINE_TEST_DATABASE_TEMPLATE"] = template.name
  if (!interrupted) {
    child = Bun.spawn({
      cmd: [process.execPath, "test", "--no-env-file", "--no-orphans", "--isolate", "--max-concurrency=1", "--timeout=1800000", "./bench/backend.test.ts"],
      cwd: root, env: environment, stdin: "inherit", stdout: "inherit", stderr: "inherit",
    })
    const code = await child.exited
    if (code !== 0) throw new Error(`Backend benchmark worker failed (${code}); no completed report was published`)
    if (interrupted) throw new Error("Backend benchmark interrupted")
    const pending = JSON.parse(readFileSync(candidate, "utf8")) as Record<string, unknown>
    if (pending["status"] !== "candidate") throw new Error("Missing candidate benchmark report")
    const report: unknown = { ...pending, status: "passed" }
    validateReport(report)
    completed = report
  }
} finally {
  await template?.dispose()
  process.off("SIGINT", interrupt)
  process.off("SIGTERM", terminate)
}
if (interrupted) process.exit(interrupted)
if (!completed) throw new Error("No completed benchmark matrix")
if (baseline !== undefined) { validateReport(baseline); console.table(compareReports(baseline, completed)) }
mkdirSync(dirname(output), { recursive: true })
// Only publish after assertions, network guards, worker hooks and DB disposal pass.
writeFileSync(output, JSON.stringify(completed, null, 2) + "\n", { flag: "wx" })
console.info(`Completed backend benchmark: ${output}`)
