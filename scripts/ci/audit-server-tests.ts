import { readFileSync, readdirSync, existsSync } from "node:fs"
import path from "node:path"
import { XMLParser } from "fast-xml-parser"

type Batch = { report: string; files: string[]; exitCode: number | null }
type Run = { lane: string; status: string; selected: string[]; batches: Batch[] }
type Testcase = { "@_name"?: string; "@_file"?: string; "@_classname"?: string; skipped?: unknown; failure?: unknown; error?: unknown }

const reportRoot = path.resolve(process.argv[2] ?? "server/.test-results")
const expectations = JSON.parse(readFileSync(path.resolve(import.meta.dir, "server-test-expectations.json"), "utf8")) as {
  requiredFiles: string[]; allowedSkips: string[]
}
const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: "@_", parseAttributeValue: false })
const failures: string[] = []
const seen = new Map<string, { executed: number; skipped: number }>()
let executed = 0
let skipped = 0

const runPaths = readdirSync(reportRoot, { recursive: true }).filter((entry): entry is string =>
  typeof entry === "string" && (entry.endsWith("/run.json") || entry === "effect-run.json"))
const runs = runPaths.map((entry) => ({ directory: path.dirname(path.join(reportRoot, entry)),
  run: JSON.parse(readFileSync(path.join(reportRoot, entry), "utf8")) as Run }))
for (const lane of ["bun", "preview", "effect", "effect-bun"]) {
  const found = runs.filter(({ run }) => run.lane === lane)
  if (found.length !== 1) failures.push(`${lane}: expected one run manifest, found ${found.length}`)
}
for (const { directory, run } of runs) {
  if (run.status !== "complete") failures.push(`${run.lane}: run did not complete`)
  if (run.selected.length === 0) failures.push(`${run.lane}: empty selection`)
  const batchSelection = run.batches.flatMap((batch) => batch.files)
  if (JSON.stringify(batchSelection.slice().sort()) !== JSON.stringify(run.selected.slice().sort())) {
    failures.push(`${run.lane}: selected files and batch inventory differ`)
  }
  for (const batch of run.batches) {
    if (batch.exitCode !== 0) failures.push(`${run.lane}/${batch.report}: runner exit ${batch.exitCode}`)
    const report = path.join(directory, batch.report)
    if (!existsSync(report)) {
      failures.push(`${run.lane}: missing ${batch.report}`)
      continue
    }
    const xml = parser.parse(readFileSync(report, "utf8")) as Record<string, unknown>
    const cases: Testcase[] = []
    collectCases(xml, cases)
    const batchSeen = new Set<string>()
    for (const test of cases) {
      const file = test["@_file"] ?? test["@_classname"]
      if (!file) {
        failures.push(`${run.lane}/${batch.report}: testcase lacks a file identity`)
        continue
      }
      if (!batch.files.includes(file)) failures.push(`${run.lane}/${batch.report}: unexpected file ${file}`)
      batchSeen.add(file)
      const id = `${file}::${test["@_name"] ?? ""}`
      const isSkipped = test.skipped !== undefined
      const isFailed = test.failure !== undefined || test.error !== undefined
      if (isSkipped) {
        skipped += 1
        if (!expectations.allowedSkips.includes(id)) failures.push(`unexpected skip: ${id}`)
      } else if (isFailed) {
        failures.push(`failed test: ${id}`)
      } else {
        executed += 1
      }
      const counts = seen.get(file) ?? { executed: 0, skipped: 0 }
      if (isSkipped) counts.skipped += 1
      else if (!isFailed) counts.executed += 1
      seen.set(file, counts)
    }
    for (const file of batch.files) if (!batchSeen.has(file)) failures.push(`${run.lane}/${batch.report}: no testcase for ${file}`)
  }
}
for (const file of expectations.requiredFiles) {
  const counts = seen.get(file)
  if (!counts || counts.executed === 0 || counts.skipped > 0) {
    failures.push(`required integration file did not fully execute: ${file} (${JSON.stringify(counts ?? {})})`)
  }
}
for (const id of expectations.allowedSkips) {
  if (!id.includes("::")) failures.push(`invalid allowed skip identity: ${id}`)
}
console.log(`Server test audit: ${runs.length} runs, ${seen.size} files, ${executed} executed, ${skipped} skipped`)
for (const [file, counts] of [...seen].sort(([a], [b]) => a.localeCompare(b))) console.log(`${file}: ${counts.executed} executed, ${counts.skipped} skipped`)
if (failures.length) {
  for (const failure of failures) console.error(`error: ${failure}`)
  process.exitCode = 1
}

function collectCases(value: unknown, result: Testcase[]) {
  if (!value || typeof value !== "object") return
  if (Array.isArray(value)) {
    for (const entry of value) collectCases(entry, result)
    return
  }
  for (const [key, child] of Object.entries(value)) {
    if (key === "testcase") result.push(...(Array.isArray(child) ? child : [child]) as Testcase[])
    else collectCases(child, result)
  }
}
