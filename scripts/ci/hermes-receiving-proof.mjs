import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"

const adapterName = "@inline-chat/hermes-agent-adapter"
const receivingScenario = "hermes-real-host-inbound-and-persisted-reply"
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

export function makeHermesReceivingReceipt({ sourceSha, host, artifactSha256 }) {
  assert.match(sourceSha, commitPattern, "Inline source SHA is required")
  assert.match(artifactSha256, artifactPattern, "exact adapter artifact SHA-256 is required")
  assert.equal(host.intakeVersion, 1, "a stock loader/send result cannot qualify receiving")
  return {
    sourceSha,
    qualification: "receiving-qualified",
    host,
    adapter: { name: adapterName, sha256: artifactSha256 },
    scenarios: [{ scenario: receivingScenario, status: "passed" }],
  }
}

export function verifyHermesReceivingReceipt(receipt, { sourceSha, artifactSha256, manifest }) {
  assert.match(sourceSha, commitPattern, "release source SHA must be exact")
  assert.match(artifactSha256, artifactPattern, "release artifact hash must be exact")
  assert.equal(receipt.qualification, "receiving-qualified", "stock compatibility is not receiving proof")
  assert.equal(receipt.sourceSha, sourceSha, "receiving proof belongs to another Inline commit")
  assertHermesReceivingHost(hermesReceivingPin(manifest), receipt.host ?? {})
  assert.equal(receipt.adapter?.name, adapterName, "receiving proof is for another adapter")
  assert.equal(receipt.adapter?.sha256, artifactSha256,
    "release bytes differ from receiving-qualified bytes; qualify the exact tarball before publication")
  assert.ok(Array.isArray(receipt.scenarios) && receipt.scenarios.length > 0
    && receipt.scenarios.every((entry) => entry.status === "passed")
    && receipt.scenarios.some((entry) => entry.scenario === receivingScenario),
  "real host inbound and persisted reply must have passed")
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
