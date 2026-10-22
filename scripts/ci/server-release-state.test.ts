import { describe, expect, it } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"

const root = path.resolve(import.meta.dir, "../..")
type Step = { name?: string; run?: string; uses?: string; if?: string; with?: Record<string, unknown> }
type Job = { steps: Step[]; needs?: string | string[]; env?: Record<string, string> }
const workflow = Bun.YAML.parse(readFileSync(path.join(root, ".github/workflows/server-deploy.yml"), "utf8")) as { jobs: Record<string, Job> }
const preflight = workflow.jobs.preflight!
const save = preflight.steps.find((step) => step.name === "Save the qualified image identities and original restore targets")!.run!
const sha = "a".repeat(40)
const oldSha = "c".repeat(40)
const runtime = `ghcr.io/inline-chat/inline-server@sha256:${"1".repeat(64)}`
const standby = `ghcr.io/inline-chat/inline-server@sha256:${"2".repeat(64)}`
const fly = { count: 1, ids: "original-fly", digest: `sha256:${"3".repeat(64)}`, revision: oldSha }
const nuremberg = { app: "app1", imageName: "127.0.0.1:5000/inline-api", imageTag: "original-tag", revision: oldSha }

function planFixture() {
  const directory = mkdtempSync(path.join(tmpdir(), "inline-release-plan-"))
  const plan = path.join(directory, "release-plan/release.json")
  const output = path.join(directory, "outputs")
  const nbgFile = path.join(directory, "nbg-baseline.json")
  mkdirSync(path.dirname(plan))
  writeFileSync(path.join(directory, "fly-baseline.json"), JSON.stringify(fly))
  writeFileSync(nbgFile, JSON.stringify(nuremberg))
  const run = (extra: Record<string, string> = {}) => {
    writeFileSync(output, "")
    const result = Bun.spawnSync(["bash", "-e", "-c", save], { cwd: root, env: {
      PATH: process.env.PATH, RUNNER_TEMP: directory, GITHUB_SHA: sha, GITHUB_RUN_ATTEMPT: "1",
      RUNTIME_IMAGE: runtime, STANDBY_IMAGE: standby, ORIGINS: "both", BOOTSTRAP: "false",
      NBG_BASELINE_FILE: nbgFile, GITHUB_OUTPUT: output, ...extra,
    } })
    return { code: result.exitCode, error: result.stderr.toString(), output: readFileSync(output, "utf8") }
  }
  return { directory, plan, nbgFile, run, cleanup: () => rmSync(directory, { recursive: true, force: true }) }
}

describe("server release restore plan", () => {
  it("retains the original image identities and baselines across a retry after configuration changes", () => {
    const f = planFixture()
    try {
      const first = f.run()
      expect(first.code, first.error).toBe(0)
      expect(first.output).toContain("created=true")
      const original = readFileSync(f.plan, "utf8")
      expect(JSON.parse(original)).toMatchObject({ schema: 1, sha, runtime_image: runtime, standby_image: standby, fly, nuremberg })
      expect(JSON.parse(original).migration_head).toBeString()
      writeFileSync(f.nbgFile, JSON.stringify({ ...nuremberg, imageName: "ghcr.io/inline-chat/inline-server@sha256", imageTag: "2".repeat(64), revision: sha }))
      writeFileSync(path.join(f.directory, "fly-baseline.json"), JSON.stringify({ ...fly, ids: "replacement-fly", revision: sha }))
      const retry = f.run({ GITHUB_RUN_ATTEMPT: "2" })
      expect(retry.code, retry.error).toBe(0)
      expect(retry.output).toContain("created=false")
      expect(retry.output).toContain(`baseline=${JSON.stringify(fly)}`)
      expect(readFileSync(f.plan, "utf8")).toBe(original)
    } finally { f.cleanup() }
  })

  it("rejects a changed source, image digest or target selection without overwriting the retained plan", () => {
    const f = planFixture()
    try {
      expect(f.run().code).toBe(0)
      const original = readFileSync(f.plan, "utf8")
      const changed: Array<Record<string, string>> = [
        { GITHUB_SHA: "b".repeat(40) }, { RUNTIME_IMAGE: standby }, { STANDBY_IMAGE: runtime },
        { ORIGINS: "nuremberg" }, { BOOTSTRAP: "true" },
      ]
      for (const extra of changed) {
        const result = f.run({ GITHUB_RUN_ATTEMPT: "2", ...extra })
        expect(result.code).not.toBe(0)
        expect(result.output).not.toContain("created=true")
        expect(readFileSync(f.plan, "utf8")).toBe(original)
      }
    } finally { f.cleanup() }
  })

  it("refuses to invent a fresh original baseline when a retry has lost its retained plan", () => {
    const f = planFixture()
    try {
      const result = f.run({ GITHUB_RUN_ATTEMPT: "2" })
      expect(result.code).not.toBe(0)
      expect(existsSync(f.plan)).toBe(false)
      expect(result.output).not.toContain("created=true")
    } finally { f.cleanup() }
  })

  it("completes configuration, read-only origin checks and durable plan retention before DDL", () => {
    expect(workflow.jobs.migrate!.needs).toEqual(["qualify", "preflight"])
    expect(workflow.jobs.nuremberg!.needs).toEqual(["qualify", "preflight", "migrate"])
    const names = preflight.steps.map((step) => step.name)
    const configuration = names.indexOf("Check required configuration and anonymous image access")
    const origins = names.indexOf("Check Coolify and the selected smoke account without sending messages")
    const record = names.indexOf("Save the qualified image identities and original restore targets")
    const retain = names.indexOf("Retain the plan before any database or origin change")
    expect(configuration).toBeGreaterThan(0)
    expect(origins).toBeGreaterThan(configuration)
    expect(record).toBeGreaterThan(origins)
    expect(retain).toBeGreaterThan(record)
    expect(preflight.steps[retain]!.with).toMatchObject({ name: "server-release-plan", "if-no-files-found": "error" })
    const checks = preflight.steps[origins]!.run!
    expect(checks).toContain("nbg-release.ts --preflight")
    expect(checks).toContain("release-smoke.ts --preflight")
    expect(checks).not.toMatch(/flyctl deploy|docker run|--allow-mutation/)
    const nbg = JSON.stringify(workflow.jobs.nuremberg)
    expect(nbg).not.toMatch(/NBG_SSH|NBG_KNOWN_HOSTS|STANDBY_RELEASE_SSH_KEY|FLY_API_TOKEN|crane|registry\.fly\.io/)
  })
})

type JobResult = { result: "success" | "skipped" | "failure" | "cancelled"; outputs?: { outcome: string } }
function report(origins: "both" | "fly" | "nuremberg", changes: Record<string, JobResult> = {}, bootstrap = false, publishOnly = false) {
  const directory = mkdtempSync(path.join(tmpdir(), "inline-server-summary-"))
  const summary = path.join(directory, "summary.md")
  const needs: Record<string, JobResult> = {
    validate: { result: "success" }, qualify: { result: "success" }, preflight: { result: "success" }, migrate: { result: "success" },
    nuremberg: { result: "success", outputs: { outcome: "published" } }, deploy: { result: "success", outputs: { outcome: "published" } },
    activate: { result: "skipped" }, prepared: { result: "skipped" }, ...changes,
  }
  try {
    const result = Bun.spawnSync(["bash", "scripts/ci/server-release-summary.sh"], { cwd: root, env: {
      PATH: process.env.PATH, ORIGINS: origins, BOOTSTRAP: String(bootstrap), PUBLISH_ONLY: String(publishOnly), RESULTS: JSON.stringify(needs),
      GITHUB_SHA: sha, GITHUB_STEP_SUMMARY: summary,
    } })
    return { code: result.exitCode, error: result.stderr.toString(), annotation: result.stdout.toString(), summary: existsSync(summary) ? readFileSync(summary, "utf8") : "" }
  } finally { rmSync(directory, { recursive: true, force: true }) }
}

describe("server release completion summary", () => {
  it("reports publication-only success and failure without claiming a server deployment", () => {
    const success = report("nuremberg", { prepared: { result: "success" } }, false, true)
    expect(success.code, success.error).toBe(0)
    expect(success.summary).toContain("Server images: Published")
    expect(success.summary).toContain("production jobs were not requested")
    const failed = report("nuremberg", { qualify: { result: "failure" } }, false, true)
    expect(failed.code, failed.error).toBe(0)
    expect(failed.summary).toContain("Server images: Failed")
    expect(failed.summary).toContain("image qualification failure")
    expect(failed.summary).not.toContain("Server release: Published")
  })
  it("reports validation, qualification, preflight and migration failures without claiming publication", () => {
    for (const [job, reason] of [["validate", "input validation"], ["qualify", "image qualification"], ["preflight", "origin/configuration preflight"], ["migrate", "migration did not pass"]]) {
      const result = report("both", { [job!]: { result: "failure" }, nuremberg: { result: "skipped" }, deploy: { result: "skipped" } })
      expect(result.code, result.error).toBe(0)
      expect(result.summary).toContain("Server release: Failed")
      expect(result.summary).toContain(reason!)
      expect(result.summary).toContain(job === "preflight" ? "this attempt did not reach migrations or deployment" : "this attempt did not reach deployment")
      expect(result.summary).not.toContain("Server release: Published")
      expect(result.annotation).toContain("::error")
    }
  })

  it("distinguishes an NBG failure from a partial release where NBG succeeded and Fly failed", () => {
    const nbg = report("both", { nuremberg: { result: "failure" }, deploy: { result: "skipped" } })
    expect(nbg.code, nbg.error).toBe(0)
    expect(nbg.summary).toContain("Nuremberg failure")
    expect(nbg.summary).toContain("Fly was not touched")
    const fly = report("both", { deploy: { result: "failure" } })
    expect(fly.code, fly.error).toBe(0)
    expect(fly.summary).toContain("Nuremberg serves this release but Fly failure")
    expect(fly.summary).not.toContain("Server release: Published")
  })

  it("requires worker activation success before calling bootstrap published", () => {
    expect(workflow.jobs.summary!.needs).toEqual(["validate", "qualify", "prepared", "preflight", "migrate", "nuremberg", "deploy", "activate"])
    for (const result of ["failure", "skipped", "cancelled"] as const) {
      const summary = report("fly", { activate: { result } }, true)
      expect(summary.code, summary.error).toBe(0)
      expect(summary.summary).toContain("Server release: Failed")
      expect(summary.summary).toContain(`worker activation ${result}`)
    }
    const success = report("fly", { activate: { result: "success" } }, true)
    expect(success.code, success.error).toBe(0)
    expect(success.summary).toContain("Server release: Published")
    expect(success.summary).toContain("worker activation verified")
  })

  it("reports existing and single-origin releases with their actual scope", () => {
    const current = report("both", { nuremberg: { result: "success", outputs: { outcome: "already-current" } }, deploy: { result: "success", outputs: { outcome: "already-current" } } })
    expect(current.code, current.error).toBe(0)
    expect(current.summary).toContain("Server release: Already current")
    const nbg = report("nuremberg", { deploy: { result: "skipped" } })
    expect(nbg.code, nbg.error).toBe(0)
    expect(nbg.summary).toContain("Nuremberg verified and smoke-tested")
    expect(nbg.summary).toContain("Fly was not updated")
    const fly = report("fly", { nuremberg: { result: "skipped" } })
    expect(fly.code, fly.error).toBe(0)
    expect(fly.summary).toContain("Fly verified and smoke-tested")
    expect(fly.summary).toContain("Nuremberg was not updated")
  })
})
