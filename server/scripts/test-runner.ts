import { mkdirSync } from "node:fs"
import { availableParallelism } from "node:os"
import { resolve } from "node:path"
import { parseArgs } from "node:util"
import { discoverTests } from "./test-discovery"
import { createTestEnvironment } from "./test-environment"
import { prepareTestDatabaseTemplate } from "./test-database-template"

const serverRoot = resolve(import.meta.dir, "..")
const separator = process.argv.indexOf("--", 2)
const forwarded = separator < 0 ? [] : process.argv.slice(separator + 1)
const { values, positionals } = parseArgs({
  args: process.argv.slice(2, separator < 0 ? undefined : separator),
  allowPositionals: true,
  options: {
    "effect-bun": { type: "boolean" }, unit: { type: "boolean" }, postgres: { type: "boolean" },
    preview: { type: "boolean" }, list: { type: "boolean" }, check: { type: "boolean" },
    jobs: { type: "string" }, "report-dir": { type: "string" },
    "no-template": { type: "boolean" }, help: { type: "boolean", short: "h" },
  },
})
if (values.help) {
  console.info(`Usage: bun run test:bun [path filters] [--jobs N] [-- Bun test flags]
  --unit         Bun tests that do not import the database lifecycle
  --postgres     Every Bun test that imports the database lifecycle
  --effect-bun   Effect integration tests requiring the Bun runtime
  --preview      URL preview workspace tests
  --list         Print the complete test inventory (or filtered selection)
  --check        Verify every test has exactly one runner
  --report-dir   Write JUnit and timing reports per batch to this directory
  --no-template  Run migrations independently in each disposable database

Files run in isolated Bun workers; tests inside each file run serially.
Use --jobs 1 to debug. Forward flags after --, e.g. -- --randomize --seed=42.
No retries. Database tests require a local TEST_DATABASE_URL and CREATEDB.
The database named by that URL is never reset or migrated.`)
  process.exit(0)
}
if ([values.unit, values.postgres, values["effect-bun"], values.preview].filter(Boolean).length > 1) {
  throw new Error("Select only one test lane.")
}
const jobs = Number(values.jobs ?? Math.min(2, availableParallelism()))
if (!Number.isInteger(jobs) || jobs < 1 || jobs > 8) throw new Error("--jobs must be an integer from 1 to 8.")
for (const flag of forwarded) {
  if (/^--(?:no-isolate|parallel|concurrent|max-concurrency|pass-with-no-tests|only|retry|preload|env-file)(?:=|$)/.test(flag)) {
    throw new Error(`Runner isolation/safety option cannot be overridden: ${flag.split("=")[0]}`)
  }
}
const inventory = discoverTests(serverRoot)
const selected = inventory.filter((file) => {
  const laneMatches = values["effect-bun"] ? file.lane === "effect-bun"
    : values.preview ? file.lane === "preview"
    : values.unit ? file.lane === "bun" && !file.usesDatabase
    : values.postgres ? (file.lane === "bun" || file.lane === "effect-bun") && file.usesDatabase
    : values.list || values.check ? true : file.lane === "bun"
  return laneMatches && (positionals.length === 0 || positionals.some((filter) => file.path.includes(filter.replace(/^\.\//, ""))))
})
if (selected.length === 0) throw new Error("No test files matched; refusing a green run with no tests.")
if (values.list || values.check) {
  if (values.list) for (const file of selected) console.info(`${file.lane.padEnd(10)} ${file.usesDatabase ? "postgres" : "isolated"} ${file.path}`)
  for (const lane of ["bun", "effect", "effect-bun", "preview"] as const) {
    const files = selected.filter((file) => file.lane === lane)
    console.info(`${lane}: ${files.length} files (${files.filter((file) => file.usesDatabase).length} use PostgreSQL)`)
  }
  process.exit(0)
}
const needsDatabase = selected.some((file) => file.usesDatabase)
const databaseUrl = needsDatabase ? process.env["TEST_DATABASE_URL"] ?? process.env["DATABASE_URL"] : undefined
if (needsDatabase && !databaseUrl) throw new Error("Database tests require a local TEST_DATABASE_URL (role needs CREATEDB).")
const environment = createTestEnvironment(process.env, databaseUrl)
const reportLane = values["effect-bun"] ? "effect-bun" : values.preview ? "preview" : values.postgres ? "postgres" : values.unit ? "unit" : "bun"
const reportRoot = values["report-dir"] ?? (process.env["CI"] ? ".test-results" : undefined)
// Native timing updates merge existing entries. A unique invocation directory
// prevents stale files from another selection from contaminating this report.
const reportDir = reportRoot ? resolve(serverRoot, reportRoot, `${reportLane}-${Date.now()}-${process.pid}`) : undefined
if (reportDir) {
  mkdirSync(reportDir, { recursive: true })
  console.info(`Test reports: ${reportDir}`)
}
// Bun's isolated VMs retain substantial process memory over a large suite.
// Recycle the worker pool after a bounded number of files; the DB template stays
// alive across batches. Every file still runs once, in a fresh module environment.
const batchSize = jobs * 6
// Unit files never receive a provisioning URL, including during the full suite.
const batches = [false, true].flatMap((usesDatabase) => {
  const files = selected.filter((file) => file.usesDatabase === usesDatabase)
  return Array.from({ length: Math.ceil(files.length / batchSize) }, (_, index) =>
    files.slice(index * batchSize, (index + 1) * batchSize),
  )
})
if (batches.length > 1 && forwarded.some((flag) => /^--(?:reporter-outfile|timings|coverage-dir)(?:=|$)/.test(flag))) {
  throw new Error("Use --report-dir for a multi-batch run so reports cannot overwrite one another.")
}
const startedAt = performance.now()
let template: Awaited<ReturnType<typeof prepareTestDatabaseTemplate>> | undefined
let child: ReturnType<typeof Bun.spawn> | undefined
let interrupted = 0
const onInterrupt = () => { interrupted = 130; child?.kill("SIGINT") }
const onTerminate = () => { interrupted = 143; child?.kill("SIGTERM") }
process.on("SIGINT", onInterrupt)
process.on("SIGTERM", onTerminate)
let exitCode = 1
try {
  if (needsDatabase && !values["no-template"]) {
    template = await prepareTestDatabaseTemplate(databaseUrl!)
    environment["INLINE_TEST_DATABASE_TEMPLATE"] = template.name
  }
  if (!interrupted) {
    console.info(`Running ${selected.length} files in ${jobs} isolated Bun workers across ${batches.length} bounded batches${template ? " with a migrated PostgreSQL template" : ""}.`)
    exitCode = 0
    for (const [index, batch] of batches.entries()) {
      if (interrupted) break
      const reportName = `${reportLane}-${String(index + 1).padStart(3, "0")}`
      const reports = reportDir ? [
        "--reporter=junit", `--reporter-outfile=${resolve(serverRoot, reportDir, `${reportName}.xml`)}`,
        `--timings=${resolve(serverRoot, reportDir, `${reportName}-timings.json`)}`, "--update-timings",
      ] : []
      const coverage = forwarded.includes("--coverage") && batches.length > 1
        ? [`--coverage-dir=${resolve(serverRoot, reportDir ?? "coverage", reportName)}`] : []
      console.info(`Batch ${index + 1}/${batches.length}: ${batch[0]!.path} ... ${batch.at(-1)!.path}`)
      child = Bun.spawn({
        cmd: [process.execPath, "test", "--no-env-file", "--no-orphans", "--isolate", `--parallel=${jobs}`,
          "--max-concurrency=1", "--timeout=30000", ...reports, ...forwarded, ...coverage,
          ...batch.map((file) => `./${file.path}`)],
        cwd: serverRoot, env: batch[0]!.usesDatabase ? environment : createTestEnvironment(process.env),
        stdin: "inherit", stdout: "inherit", stderr: "inherit",
      })
      const batchExit = await child.exited
      if (batchExit !== 0) exitCode = batchExit
    }
  }
} finally {
  await template?.dispose()
  process.off("SIGINT", onInterrupt)
  process.off("SIGTERM", onTerminate)
  console.info(`Suite finished in ${((performance.now() - startedAt) / 1_000).toFixed(2)}s.`)
}
process.exit(interrupted || exitCode)
