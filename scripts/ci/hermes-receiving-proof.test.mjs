import { describe, expect, it } from "bun:test"
import { execFileSync, spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { assertHermesReceivingHost, hermesReceivingPin, makeHermesReceivingReceipt,
  selectHermesReceivingRun, verifyHermesReceivingReceipt } from "./hermes-receiving-proof.mjs"

const root = path.resolve(import.meta.dir, "../..")
const manifest = { name: "@inline-chat/hermes-agent-adapter", version: "0.0.22", inlineHermes: {
  testedHermesRepository: "morajabi/hermes-agent", testedHermesCommit: "a".repeat(40),
} }
const sourceSha = "b".repeat(40)
const artifactSha256 = "c".repeat(64)
const host = { repository: "morajabi/hermes-agent", sha: "a".repeat(40), intakeVersion: 1 }
const requiredScenarios = [
  "hermes-real-host-inbound-and-persisted-reply",
  "hermes-acknowledged-pending-process-death-recovery",
  "hermes-pending-edited-current-source",
  "hermes-pending-deleted-source-settlement",
  "hermes-pending-revoked-access-settlement",
  "hermes-receiver-profile-mismatch-refused",
  "hermes-control-command-excluded-from-replay",
  "hermes-atomic-user-row-consumption-and-no-replay",
]
const observed = (artifactHash = artifactSha256) => ({ sourceSha, host: { ...host },
  adapter: { name: manifest.name, sha256: artifactHash },
  scenarios: requiredScenarios.map((scenario) => ({ scenario, status: "passed" })),
})
const make = (report = observed()) => makeHermesReceivingReceipt({ sourceSha, artifactSha256, host: { ...host }, report })
const verify = (receipt) => verifyHermesReceivingReceipt(receipt, { sourceSha, artifactSha256, manifest })

describe("Hermes receiving qualification", () => {
  it("requires an exact repository/commit pin and the matching intake capability", () => {
    expect(hermesReceivingPin(manifest)).toEqual({ repository: host.repository, sha: host.sha })
    for (const fields of [{}, { testedHermesRepository: "../private-home", testedHermesCommit: host.sha },
      { testedHermesRepository: host.repository, testedHermesCommit: "latest" }]) {
      expect(() => hermesReceivingPin({ ...manifest, inlineHermes: fields })).toThrow()
    }
    for (const actual of [{ ...host, repository: "NousResearch/hermes-agent" }, { ...host, sha: "d".repeat(40) },
      { ...host, intakeVersion: undefined }]) {
      expect(() => assertHermesReceivingHost(hermesReceivingPin(manifest), actual)).toThrow()
    }
  })

  it("accepts only the exact source, owning core and artifact bytes after real receiving", () => {
    expect(() => verify(make())).not.toThrow()
    const wrongSource = make()
    wrongSource.sourceSha = "d".repeat(40)
    const wrongArtifact = make()
    wrongArtifact.adapter.sha256 = "e".repeat(64)
    const wrongCore = make()
    wrongCore.host.sha = "f".repeat(40)
    const failedFlow = make()
    failedFlow.scenarios[0].status = "failed"
    const stockOnly = make()
    stockOnly.qualification = "loader/send-only"
    const noFlow = make()
    noFlow.scenarios = []
    for (const receipt of [wrongSource, wrongArtifact, wrongCore, failedFlow, stockOnly, noFlow]) {
      expect(() => verify(receipt)).toThrow()
    }
    expect(() => verifyHermesReceivingReceipt({ sourceSha, scenarios: [{ scenario: "legacy", status: "passed" }] },
      { sourceSha, artifactSha256, manifest })).toThrow()
  })

  it("cannot qualify a successful exit or normal reply without the explicit full observed report", () => {
    expect(() => makeHermesReceivingReceipt({ sourceSha, artifactSha256, host })).toThrow("observed Python receiving report")
    const normalOnly = observed()
    normalOnly.scenarios = [normalOnly.scenarios[0]]
    expect(() => make(normalOnly)).toThrow("required receiving scenario was not observed")
    expect(() => verify({ ...normalOnly, qualification: "receiving-qualified" })).toThrow("required receiving scenario was not observed")
    const noScenarios = observed()
    delete noScenarios.scenarios
    expect(() => make(noScenarios)).toThrow("observed receiving scenarios are required")
  })

  it("requires every recovery and authority scenario exactly once and passed at both gates", () => {
    for (const scenario of requiredScenarios) {
      const omitted = observed()
      omitted.scenarios = omitted.scenarios.filter((entry) => entry.scenario !== scenario)
      const failed = observed()
      failed.scenarios.find((entry) => entry.scenario === scenario).status = "failed"
      const duplicated = observed()
      duplicated.scenarios.push({ scenario, status: "passed" })
      for (const report of [omitted, failed, duplicated]) {
        expect(() => make(report)).toThrow()
        expect(() => verify({ ...report, qualification: "receiving-qualified" })).toThrow()
      }
    }
    const foreignCase = observed()
    foreignCase.scenarios[0].scenario = "hermes-stock-loader-only"
    expect(() => make(foreignCase)).toThrow("unrecognized receiving scenario")
    expect(() => verify({ ...foreignCase, qualification: "receiving-qualified" })).toThrow("unrecognized receiving scenario")
  })

  it("refuses observed reports from a foreign source, core, capability or artifact before creating a receipt", () => {
    const wrongSource = observed()
    wrongSource.sourceSha = "d".repeat(40)
    const wrongRepository = observed()
    wrongRepository.host.repository = "NousResearch/hermes-agent"
    const wrongCore = observed()
    wrongCore.host.sha = "e".repeat(40)
    const stockCore = observed()
    stockCore.host.intakeVersion = 0
    const wrongAdapter = observed()
    wrongAdapter.adapter.name = "other-adapter"
    const wrongArtifact = observed("f".repeat(64))
    for (const report of [wrongSource, wrongRepository, wrongCore, stockCore, wrongAdapter, wrongArtifact]) {
      expect(() => make(report)).toThrow()
      expect(() => verify({ ...report, qualification: "receiving-qualified" })).toThrow()
    }
  })

  it("preserves observed assertion details without sharing mutable scenario records", () => {
    const report = observed()
    report.scenarios[1].assertions = { acknowledgedBeforeKill: true, adoptedBeforeAck: true }
    const receipt = make(report)
    expect(receipt.scenarios).toEqual(report.scenarios)
    expect(receipt.scenarios).not.toBe(report.scenarios)
    report.scenarios[1].status = "failed"
    report.scenarios[1].assertions.acknowledgedBeforeKill = false
    expect(receipt.scenarios[1].status).toBe("passed")
    expect(receipt.scenarios[1].assertions.acknowledgedBeforeKill).toBe(true)
    expect(() => verify(receipt)).not.toThrow()
  })

  it("selects only a successful push CI run on the same repository's exact main commit", () => {
    const valid = { id: 42, head_sha: sourceSha, head_branch: "main", event: "push", status: "completed",
      conclusion: "success", head_repository: { full_name: "inline-chat/inline" } }
    const untrusted = [{ ...valid, id: 1, event: "pull_request" }, { ...valid, id: 2, head_sha: "d".repeat(40) },
      { ...valid, id: 3, conclusion: "failure" }, { ...valid, id: 4, head_repository: { full_name: "other/inline" } },
      { ...valid, id: 5, head_branch: "candidate" }]
    expect(selectHermesReceivingRun({ workflow_runs: [...untrusted, valid] },
      { sourceSha, repository: "inline-chat/inline" })).toBe(42)
    expect(() => selectHermesReceivingRun({ workflow_runs: untrusted }, { sourceSha, repository: "inline-chat/inline" })).toThrow()
  })

  it("verifies the actual release tarball and rejects a changed repack or missing proof", () => {
    const scratch = mkdtempSync(path.join(os.tmpdir(), "inline-hermes-proof-"))
    mkdirSync(path.join(scratch, "package"))
    writeFileSync(path.join(scratch, "package/package.json"), JSON.stringify(manifest))
    const artifact = path.join(scratch, "adapter.tgz")
    const pack = () => execFileSync("tar", ["-czf", artifact, "-C", scratch, "package"])
    pack()
    const hash = createHash("sha256").update(readFileSync(artifact)).digest("hex")
    const receiptFile = path.join(scratch, "receipt.json")
    const receipt = makeHermesReceivingReceipt({ sourceSha, host, artifactSha256: hash, report: observed(hash) })
    writeFileSync(receiptFile, JSON.stringify(receipt))
    const run = (file = receiptFile) => spawnSync("node", [path.join(root, "scripts/ci/hermes-receiving-proof.mjs"),
      "verify", file, artifact, sourceSha], { encoding: "utf8", timeout: 10_000 })
    expect(run().status).toBe(0)
    writeFileSync(receiptFile, JSON.stringify({ ...receipt, scenarios: [receipt.scenarios[0]] }))
    const normalOnly = run()
    expect(normalOnly.status).not.toBe(0)
    expect(normalOnly.stderr).toContain("required receiving scenario was not observed")
    writeFileSync(receiptFile, JSON.stringify({ ...receipt, scenarios: [...receipt.scenarios, receipt.scenarios[1]] }))
    const duplicated = run()
    expect(duplicated.status).not.toBe(0)
    expect(duplicated.stderr).toContain("receiving scenario reported more than once")
    writeFileSync(receiptFile, JSON.stringify(receipt))
    writeFileSync(path.join(scratch, "package/changed.txt"), "different release bytes")
    pack()
    const changed = run()
    expect(changed.status).not.toBe(0)
    expect(changed.stderr).toContain("release bytes differ")
    expect(run(path.join(scratch, "absent.json")).status).not.toBe(0)
  })
})
