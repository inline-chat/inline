import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"

const adapterName = "@inline-chat/hermes-agent-adapter"
const receivingScenarios = [
  "hermes-real-host-inbound-and-persisted-reply",
  "hermes-acknowledged-pending-process-death-recovery",
  "hermes-pending-edited-current-source",
  "hermes-pending-deleted-source-settlement",
  "hermes-pending-revoked-access-settlement",
  "hermes-receiver-profile-mismatch-refused",
  "hermes-control-command-excluded-from-replay",
  "hermes-atomic-user-row-consumption-and-no-replay",
]
const repositoryPattern = /^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/
const commitPattern = /^[a-f0-9]{40}$/
const artifactPattern = /^[a-f0-9]{64}$/

export function hermesReceivingPin(manifest) {
  const { testedHermesRepository: repository, testedHermesCommit: sha } = manifest.inlineHermes ?? {}
  assert.equal(manifest.name, adapterName, "receiving pin must belong to the adapter")
  assert.equal(typeof repository, "string", "reviewed Hermes repository is required")
  assert.match(repository, repositoryPattern, "reviewed Hermes repository must be a GitHub OWNER/REPO")
  assert.equal(typeof sha, "string", "reviewed Hermes commit is required")
  assert.match(sha, commitPattern, "reviewed Hermes commit must be an exact lowercase 40-hex SHA")
  return { repository, sha }
}

export function assertHermesReceivingHost(pin, host) {
  assert.equal(host.repository, pin.repository, "receiving host repository differs from the artifact pin")
  assert.equal(host.sha, pin.sha, "receiving host commit differs from the artifact pin")
  assert.equal(host.intakeVersion, 1, "receiving requires the matching durable-intake core v1")
}

function assertObservedReceivingReport(report, { sourceSha, host, artifactSha256 }) {
  assert.ok(report && typeof report === "object", "observed Python receiving report is required")
  assert.equal(report.sourceSha, sourceSha, "receiving proof belongs to another Inline commit")
  assertHermesReceivingHost(host, report.host ?? {})
  assert.equal(report.adapter?.name, adapterName, "receiving proof is for another adapter")
  assert.equal(report.adapter?.sha256, artifactSha256,
    "release bytes differ from receiving-qualified bytes; qualify the exact tarball before publication")
  assert.ok(Array.isArray(report.scenarios), "observed receiving scenarios are required")
  const observed = new Set()
  for (const entry of report.scenarios) {
    assert.ok(receivingScenarios.includes(entry?.scenario), "unrecognized receiving scenario")
    assert.ok(!observed.has(entry.scenario), `receiving scenario reported more than once: ${entry.scenario}`)
    assert.equal(entry.status, "passed", `receiving scenario must pass: ${entry.scenario}`)
    observed.add(entry.scenario)
  }
  for (const scenario of receivingScenarios) {
    assert.ok(observed.has(scenario), `required receiving scenario was not observed: ${scenario}`)
  }
}

export function makeHermesReceivingReceipt({ sourceSha, host, artifactSha256, report }) {
  assert.match(sourceSha, commitPattern, "Inline source SHA is required")
  assert.match(artifactSha256, artifactPattern, "exact adapter artifact SHA-256 is required")
  assert.match(host.repository, repositoryPattern, "actual receiving host repository is required")
  assert.match(host.sha, commitPattern, "actual receiving host commit must be exact")
  assert.equal(host.intakeVersion, 1, "a stock loader/send result cannot qualify receiving")
  assertObservedReceivingReport(report, { sourceSha, host, artifactSha256 })
  return {
    sourceSha,
    qualification: "receiving-qualified",
    host,
    adapter: { name: adapterName, sha256: artifactSha256 },
    scenarios: structuredClone(report.scenarios),
  }
}

export function verifyHermesReceivingReceipt(receipt, { sourceSha, artifactSha256, manifest }) {
  assert.match(sourceSha, commitPattern, "release source SHA must be exact")
  assert.match(artifactSha256, artifactPattern, "release artifact hash must be exact")
  assert.equal(receipt.qualification, "receiving-qualified", "stock compatibility is not receiving proof")
  assertObservedReceivingReport(receipt, { sourceSha, artifactSha256, host: hermesReceivingPin(manifest) })
}

export function selectHermesReceivingRun(runs, { sourceSha, repository }) {
  assert.match(sourceSha, commitPattern, "CI source SHA must be exact")
  assert.match(repository, repositoryPattern, "CI repository must be OWNER/REPO")
  const run = runs.workflow_runs?.find((entry) => entry.head_sha === sourceSha
    && entry.event === "push" && entry.head_branch === "main"
    && entry.head_repository?.full_name === repository
    && entry.status === "completed" && entry.conclusion === "success")
  assert.ok(Number.isSafeInteger(run?.id) && run.id > 0,
    "no successful trusted-main CI run exists for the exact release source")
  return run.id
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, ...args] = process.argv.slice(2)
  if (mode === "select-run" && args.length === 3) {
    const [runsFile, sourceSha, repository] = args
    const runId = selectHermesReceivingRun(JSON.parse(await readFile(runsFile, "utf8")), { sourceSha, repository })
    console.log(`run-id=${runId}`)
  } else if (mode === "verify" && args.length === 3) {
    const [receiptFile, artifact, sourceSha] = args
    const manifest = JSON.parse(execFileSync("tar", ["-xOzf", artifact, "package/package.json"], {
      encoding: "utf8", maxBuffer: 1024 * 1024,
    }))
    verifyHermesReceivingReceipt(JSON.parse(await readFile(receiptFile, "utf8")), {
      sourceSha,
      artifactSha256: createHash("sha256").update(await readFile(artifact)).digest("hex"),
      manifest,
    })
    console.log(`Exact Hermes release artifact has matching-core receiving proof for ${sourceSha}`)
  } else {
    throw new Error("usage: hermes-receiving-proof.mjs {select-run RUNS_JSON SOURCE_SHA OWNER/REPO|verify RECEIPT TARBALL SOURCE_SHA}")
  }
}
