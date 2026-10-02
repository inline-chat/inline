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
const make = () => makeHermesReceivingReceipt({ sourceSha, artifactSha256, host: { ...host } })
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
    writeFileSync(receiptFile, JSON.stringify(makeHermesReceivingReceipt({ sourceSha, host, artifactSha256: hash })))
    const run = (file = receiptFile) => spawnSync("node", [path.join(root, "scripts/ci/hermes-receiving-proof.mjs"),
      "verify", file, artifact, sourceSha], { encoding: "utf8", timeout: 10_000 })
    expect(run().status).toBe(0)
    writeFileSync(path.join(scratch, "package/changed.txt"), "different release bytes")
    pack()
    const changed = run()
    expect(changed.status).not.toBe(0)
    expect(changed.stderr).toContain("release bytes differ")
    expect(run(path.join(scratch, "absent.json")).status).not.toBe(0)
  })
})
