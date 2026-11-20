import { describe, expect, it } from "bun:test"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"

const root = path.resolve(import.meta.dir, "../..")
type Step = { name?: string; run?: string; uses?: string; if?: string; with?: Record<string, unknown> }
type Job = { steps: Step[]; needs?: string | string[]; env?: Record<string, string>; if?: string; environment?: string; permissions?: Record<string, string> }
const workflow = Bun.YAML.parse(readFileSync(path.join(root, ".github/workflows/server-deploy.yml"), "utf8")) as {
  jobs: Record<string, Job & { concurrency?: Record<string, unknown> }>; on: { workflow_dispatch: { inputs: Record<string, { type: string; default: unknown }> } }
  concurrency?: unknown
}
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
  // Earlier attempts' jobs, as the GitHub API would report them to `gh api --jq`.
  mkdirSync(path.join(directory, "bin"))
  writeFileSync(path.join(directory, "bin/gh"), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$STUB_GH_CALLS"\necho "${STUB_REACHED:-0}"\n')
  chmodSync(path.join(directory, "bin/gh"), 0o700)
  writeFileSync(path.join(directory, "fly-baseline.json"), JSON.stringify(fly))
  writeFileSync(nbgFile, JSON.stringify(nuremberg))
  const run = (extra: Record<string, string> = {}) => {
    writeFileSync(output, "")
    const result = Bun.spawnSync(["bash", "-e", "-c", save], { cwd: root, env: {
      PATH: `${path.join(directory, "bin")}:${process.env.PATH}`, STUB_GH_CALLS: path.join(directory, "gh-calls"),
      GITHUB_REPOSITORY: "inline-chat/inline", GITHUB_RUN_ID: "77", RUNNER_TEMP: directory, GITHUB_SHA: sha, GITHUB_RUN_ATTEMPT: "1",
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

  it("refuses to invent a fresh original baseline when an earlier attempt reached migrations or an origin", () => {
    const f = planFixture()
    try {
      const result = f.run({ GITHUB_RUN_ATTEMPT: "3", STUB_REACHED: "1" })
      expect(result.code).not.toBe(0)
      expect(result.error).toContain("start a new dispatch")
      expect(existsSync(f.plan)).toBe(false)
      expect(result.output).not.toContain("created=true")
    } finally { f.cleanup() }
  })

  it("records the plan on a rerun when no earlier attempt got past the gate or preflight", () => {
    const f = planFixture()
    try {
      const result = f.run({ GITHUB_RUN_ATTEMPT: "3", STUB_REACHED: "0" })
      expect(result.code, result.error).toBe(0)
      expect(result.output).toContain("created=true")
      expect(JSON.parse(readFileSync(f.plan, "utf8"))).toMatchObject({ schema: 1, sha, fly })
      expect(readFileSync(path.join(f.directory, "gh-calls"), "utf8").trim().split("\n").map((line) => line.split(" ")[1])).toEqual([
        "repos/inline-chat/inline/actions/runs/77/attempts/1/jobs?per_page=100",
        "repos/inline-chat/inline/actions/runs/77/attempts/2/jobs?per_page=100",
      ])
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

describe("cross-origin qualification caller", () => {
  const readonly = preflight.steps.find((step) => step.name === "Verify the dedicated cross-origin fixture without sending messages")!
  const live = workflow.jobs.deploy!.steps.find((step) => step.name === "Verify large live messages across both origins")!

  it("checks the fixture before recording the migration plan and mutates only after canonical postflight", () => {
    expect(preflight.steps.indexOf(readonly)).toBeLessThan(preflight.steps.findIndex((step) => step.name?.startsWith("Save the qualified")))
    const deploy = workflow.jobs.deploy!.steps
    expect(deploy.indexOf(live)).toBeGreaterThan(deploy.findIndex((step) => step.name === "Smoke-test the canonical route"))
    for (const step of [readonly, live]) expect(step.if).toBe("${{ !inputs.bootstrap && inputs.origins == 'both' }}")
  })

  it("runs the exact qualified image with credentials forwarded by name, and refuses mutable image tags", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "cross-origin-caller-"))
    const executable = path.join(directory, "docker")
    const argsFile = path.join(directory, "args")
    writeFileSync(executable, '#!/bin/sh\ntest "$SMOKE_BOT_TOKEN" = fixture-token || exit 9\nprintf "%s\\n" "$@" > "$PROBE_ARGS"\n')
    chmodSync(executable, 0o700)
    const run = (step: Step, image: string) => Bun.spawnSync(["bash", "-e", "-c", step.run!], { cwd: root, env: {
      PATH: `${directory}:${process.env.PATH}`, PROBE_ARGS: argsFile, RUNTIME_IMAGE: image,
      SMOKE_BOT_TOKEN: "fixture-token", SMOKE_CHAT_ID: "7", FLY_ORIGIN_IP: "203.0.113.1", NBG_ORIGIN_IP: "203.0.113.2", GITHUB_SHA: sha,
    } })
    try {
      for (const [step, mode] of [[readonly, "--preflight"], [live, "--confirm-test-writes"]] as const) {
        expect(run(step, runtime).exitCode).toBe(0)
        const args = readFileSync(argsFile, "utf8").trim().split("\n")
        expect(args).toContain(runtime)
        expect(args).toContain("server/dist/realtime-cross-origin-smoke.js")
        expect(args).toContain("--no-env-file")
        expect(args).toContain(mode)
        expect(args).toContain("SMOKE_BOT_TOKEN")
        expect(args).not.toContain("fixture-token")
        expect(args).toContain("203.0.113.1")
        expect(args).toContain("203.0.113.2")
        expect(run(step, "ghcr.io/inline-chat/inline-server:latest").exitCode).not.toBe(0)
      }
    } finally { rmSync(directory, { recursive: true, force: true }) }
  })
})

type JobResult = { result: "success" | "skipped" | "failure" | "cancelled"; outputs?: { outcome: string } }
function report(origins: "both" | "fly" | "nuremberg", changes: Record<string, JobResult> = {}, bootstrap = false, publishOnly = false, extra: Record<string, string> = {}) {
  const directory = mkdtempSync(path.join(tmpdir(), "inline-server-summary-"))
  const summary = path.join(directory, "summary.md")
  const needs: Record<string, JobResult> = {
    validate: { result: "success" }, qualify: { result: "success" }, preflight: { result: "success" }, migrate: { result: "success" },
    nuremberg: { result: "success", outputs: { outcome: "published" } }, deploy: { result: "success", outputs: { outcome: "published" } },
    activate: { result: "skipped" }, prepared: { result: "skipped" }, require_green: { result: "success" },
    rollback_plan: { result: "skipped" }, rollback_fly: { result: "skipped" }, rollback_nuremberg: { result: "skipped" }, ...changes,
  }
  try {
    const result = Bun.spawnSync(["bash", "scripts/ci/server-release-summary.sh"], { cwd: root, env: {
      PATH: process.env.PATH, ORIGINS: origins, BOOTSTRAP: String(bootstrap), PUBLISH_ONLY: String(publishOnly), RESULTS: JSON.stringify(needs),
      GITHUB_SHA: sha, GITHUB_STEP_SUMMARY: summary, ...extra,
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
    expect(workflow.jobs.summary!.needs).toEqual(["validate", "require_green", "qualify", "prepared", "preflight", "migrate", "nuremberg", "deploy", "activate",
      "rollback_plan", "rollback_nuremberg", "rollback_fly"])
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

describe("soft deploy gate", () => {
  const validate = workflow.jobs.validate!.steps[0]!.run!
  const check = (env: Record<string, string>) => Bun.spawnSync(["bash", "-e", "-c", validate], { cwd: root, env: {
    PATH: process.env.PATH, GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REPOSITORY: "inline-chat/inline", GITHUB_REF_TYPE: "branch",
    GITHUB_REF: "refs/heads/main", PUBLISH_ONLY: "false", BOOTSTRAP: "false", ORIGINS: "both", ROLLBACK: "false", PLAN_RUN: "",
    SKIP_GATE: "false", SKIP_REASON: "", ...env,
  } }).exitCode

  it("adds incident inputs that default to the gated release", () => {
    const inputs = workflow.on.workflow_dispatch.inputs
    expect(inputs.skip_gate).toMatchObject({ type: "boolean", default: false })
    expect(inputs.skip_reason).toMatchObject({ type: "string", default: "" })
    expect(inputs.rollback_to_plan).toMatchObject({ type: "boolean", default: false })
    expect(inputs.rollback_plan_run).toMatchObject({ type: "string", default: "" })
  })

  it("requires a reason to skip and keeps rollback on main without publication or bootstrap", () => {
    expect(check({})).toBe(0)
    expect(check({ SKIP_GATE: "true", SKIP_REASON: "incident: API 500s" })).toBe(0)
    expect(check({ SKIP_GATE: "true", SKIP_REASON: " \n " })).not.toBe(0)
    expect(check({ SKIP_GATE: "false", SKIP_REASON: "forgot the checkbox" })).not.toBe(0)
    expect(check({ ROLLBACK: "true" })).toBe(0)
    expect(check({ ROLLBACK: "true", PLAN_RUN: "44046419202" })).toBe(0)
    expect(check({ ROLLBACK: "true", PLAN_RUN: "1;rm" })).not.toBe(0)
    expect(check({ ROLLBACK: "false", PLAN_RUN: "44046419202" })).not.toBe(0)
    expect(check({ ROLLBACK: "true", BOOTSTRAP: "true", ORIGINS: "fly" })).not.toBe(0)
    expect(check({ ROLLBACK: "true", PUBLISH_ONLY: "true", GITHUB_REF: "refs/heads/feature" })).not.toBe(0)
  })

  it("runs beside qualification and holds every production job behind it", () => {
    const gate = workflow.jobs.require_green!
    expect(gate.needs).toBe("validate")
    expect(gate.environment).toBeUndefined()
    expect(gate.permissions).toEqual({ contents: "read", actions: "read" })
    expect(gate.steps.at(-1)!.run).toBe("bun --no-env-file scripts/ci/require-green.ts --wait")
    expect(JSON.stringify(gate)).not.toMatch(/secrets\./)
    expect(workflow.jobs.qualify!.needs).toBe("validate")
    expect(workflow.jobs.preflight!.needs).toEqual(["qualify", "require_green"])
    // skip_gate does not depend on the gate job's checkout or Bun setup.
    for (const step of gate.steps) expect(step.if).toBe(step.name === "Record the incident bypass" ? "${{ inputs.skip_gate }}" : "${{ !inputs.skip_gate }}")
    expect(workflow.jobs.preflight!.if).toContain("(needs.require_green.result == 'success' || inputs.skip_gate)")
  })

  it("records the bypass reason as one bounded line without running the gate", () => {
    const record = workflow.jobs.require_green!.steps[0]!.run!
    const directory = mkdtempSync(path.join(tmpdir(), "inline-gate-skip-"))
    try {
      const summary = path.join(directory, "summary.md")
      const result = Bun.spawnSync(["bash", "-e", "-c", record], { env: { PATH: process.env.PATH, GITHUB_ACTOR: "mo", GITHUB_SHA: sha,
        GITHUB_STEP_SUMMARY: summary, SKIP_REASON: "incident 42:\n500s `now` <b> 100%" } })
      expect(result.exitCode).toBe(0)
      expect(readFileSync(summary, "utf8")).toContain("Deploy gate: skipped by mo\n\n> incident 42: 500s 'now' 'b' 100%")
      expect(result.stdout.toString().trim()).toBe("::warning title=Deploy gate skipped by mo::incident 42: 500s 'now' 'b' 100%25")
    } finally { rmSync(directory, { recursive: true, force: true }) }
  })

  it("keeps one run-level production lock, so releases and rollbacks never interleave", () => {
    expect(workflow.concurrency).toEqual({ group: "server-deploy-production", "cancel-in-progress": false })
    for (const [id, job] of Object.entries(workflow.jobs)) expect(job.concurrency, id).toBeUndefined()
    // A waiting gate holds that lock no longer than qualification does.
    expect((workflow.jobs.require_green as unknown as { "timeout-minutes": number })["timeout-minutes"]).toBeLessThanOrEqual(20)
  })

  it("never lets a failed gate job skip the production chain once skip_gate admitted preflight", () => {
    expect(workflow.jobs.migrate!.if).toBe("${{ !cancelled() && github.ref == 'refs/heads/main' && !inputs.publish_only && needs.preflight.result == 'success' }}")
    for (const job of ["preflight", "migrate", "nuremberg", "deploy", "activate"]) expect(workflow.jobs[job]!.if, job).toContain("!cancelled()")
    expect(workflow.jobs.activate!.if).toContain("needs.deploy.result == 'success'")
  })

  it("reports a red gate without claiming any production change, and records a skip", () => {
    const red = report("both", { require_green: { result: "failure" }, preflight: { result: "skipped" }, migrate: { result: "skipped" },
      nuremberg: { result: "skipped" }, deploy: { result: "skipped" } })
    const bypassed = report("both", { require_green: { result: "failure" } }, false, false, { SKIP_GATE: "true" })
    expect(bypassed.summary).toContain("Server release: Published")
    expect(red.code, red.error).toBe(0)
    expect(red.summary).toContain("Server release: Failed")
    expect(red.summary).toContain("deploy gate failure")
    expect(red.summary).toContain("skip_gate")
    const skipped = report("both", {}, false, false, { SKIP_GATE: "true" })
    expect(skipped.summary).toContain("Server release: Published")
    expect(skipped.summary).toContain("Deploy gate skipped")
  })
})

describe("rollback_to_plan", () => {
  const jobs = workflow.jobs
  const rollbackJobs = ["rollback_plan", "rollback_nuremberg", "rollback_fly"]

  it("skips the gate, qualification and migrations, and never receives DDL credentials", () => {
    expect(jobs.require_green!.if).toContain("!inputs.rollback_to_plan")
    expect(jobs.qualify!.if).toBe("${{ !inputs.rollback_to_plan }}")
    // preflight, migrate, nuremberg and deploy all need qualify and are skipped with it.
    for (const job of ["preflight", "migrate", "nuremberg", "deploy"]) expect([jobs[job]!.needs].flat()).toContain("qualify")
    for (const job of rollbackJobs) {
      expect([jobs[job]!.needs].flat()).not.toContain("qualify")
      expect(jobs[job]!.if).toContain("inputs.rollback_to_plan")
      expect(JSON.stringify(jobs[job])).not.toMatch(/PRODUCTION_DATABASE_MIGRATION_URL|migrate\.js|server-release-plan"/)
    }
    expect(jobs.rollback_plan!.environment).toBeUndefined()
    expect(JSON.stringify(jobs.rollback_plan)).not.toMatch(/secrets\./)
  })

  it("rolls Fly back independently of Nuremberg, from an immutable verified image, and reuses the release health wait", () => {
    expect(jobs.rollback_fly!.needs).toEqual(["validate", "rollback_plan"])
    expect(jobs.rollback_nuremberg!.needs).toEqual(["validate", "rollback_plan"])
    const fly = jobs.rollback_fly!.steps.map((step) => step.run ?? "").join("\n")
    expect(fly).toContain("scripts/ci/fly-release-machines-rollback.jq")
    expect(fly).toContain("--strategy bluegreen --ha=false")
    expect(fly).toContain("bash scripts/ci/fly-release-wait.sh")
    expect(fly).toContain('org.opencontainers.image.revision" }}\' "$TARGET_IMAGE")" = "$TARGET_REVISION"')
    expect(jobs.rollback_nuremberg!.steps.map((step) => step.run ?? "").join("\n")).toContain("nbg-release.ts --rollback")
  })

  it("refuses a mutable or mismatched Fly rollback image before contacting Fly", () => {
    const verify = jobs.rollback_fly!.steps.find((step) => step.name?.startsWith("Verify the recorded image"))!.run!
    const directory = mkdtempSync(path.join(tmpdir(), "inline-rollback-image-"))
    try {
      writeFileSync(path.join(directory, "docker"), '#!/bin/sh\nif [ "$1" = image ]; then echo "$LABEL"; fi\n')
      chmodSync(path.join(directory, "docker"), 0o700)
      const run = (image: string, label = sha) => Bun.spawnSync(["bash", "-e", "-c", verify], { cwd: root, env: {
        PATH: `${directory}:${process.env.PATH}`, RUNNER_TEMP: directory, TARGET_IMAGE: image, TARGET_REVISION: sha, LABEL: label,
      } }).exitCode
      expect(run(runtime)).toBe(0)
      expect(run(runtime, oldSha)).not.toBe(0)
      expect(run("ghcr.io/inline-chat/inline-server:latest")).not.toBe(0)
    } finally { rmSync(directory, { recursive: true, force: true }) }
  })

  it("warns and stops when healthy Fly already serves the baseline, but redeploys it over unhealthy Machines", () => {
    const replace = jobs.rollback_fly!.steps.find((step) => step.name === "Redeploy the recorded digest over the current public Machines")!.run!
    const digest = `sha256:${"1".repeat(64)}`
    const machine = (status: string) => ({ id: "m1", state: "started", host_status: "ok", cordoned: false,
      image_ref: { repository: "inline-chat/inline-server", tag: "", digest, labels: { "org.opencontainers.image.revision": sha } },
      config: { metadata: { fly_platform_version: "v2", fly_process_group: "app" }, services: [{ internal_port: 8000, checks: [{ path: "/readyz" }] }] },
      checks: [{ status }] })
    for (const [status, deployed, attempt] of [["passing", false, "1"], ["passing", false, "2"], ["critical", true, "1"]] as const) {
      const directory = mkdtempSync(path.join(tmpdir(), "inline-rollback-fly-"))
      try {
        writeFileSync(path.join(directory, "inventory.json"), JSON.stringify([machine(status)]))
        writeFileSync(path.join(directory, "flyctl"), '#!/bin/sh\nif [ "$1 $2" = "machine list" ]; then cat "$INVENTORY"; else echo "$@" > "$DEPLOYED"; fi\n')
        chmodSync(path.join(directory, "flyctl"), 0o700)
        const output = path.join(directory, "output")
        writeFileSync(output, "")
        const result = Bun.spawnSync(["bash", "-e", "-c", replace], { cwd: root, env: {
          PATH: `${directory}:${process.env.PATH}`, RUNNER_TEMP: directory, GITHUB_OUTPUT: output, FLY_API_TOKEN: "t",
          INVENTORY: path.join(directory, "inventory.json"), DEPLOYED: path.join(directory, "deployed"),
          TARGET_IMAGE: `ghcr.io/inline-chat/inline-server@${digest}`, TARGET_REVISION: sha, GITHUB_RUN_ATTEMPT: attempt,
        } })
        expect(result.exitCode, result.stderr.toString()).toBe(0)
        expect(existsSync(path.join(directory, "deployed"))).toBe(deployed)
        expect(readFileSync(output, "utf8")).toContain(deployed ? "outcome=published" : "outcome=already-current")
        // A rerun finds the rollback an earlier attempt made, so it does not blame the selected plan.
        if (!deployed) expect(result.stdout.toString()).toContain(attempt === "1" ? "::warning title=Nothing to roll back on Fly::" : "::notice title=Fly already rolled back::")
      } finally { rmSync(directory, { recursive: true, force: true }) }
    }
  })

  it("reports a complete, partial, current or unavailable rollback", () => {
    const rollback = (changes: Record<string, JobResult>) => report("both", { qualify: { result: "skipped" }, preflight: { result: "skipped" },
      migrate: { result: "skipped" }, nuremberg: { result: "skipped" }, deploy: { result: "skipped" }, require_green: { result: "skipped" },
      rollback_plan: { result: "success" }, ...changes }, false, false, { ROLLBACK: "true" })
    const done = rollback({ rollback_fly: { result: "success", outputs: { outcome: "published" } }, rollback_nuremberg: { result: "success", outputs: { outcome: "published" } } })
    expect(done.code, done.error).toBe(0)
    expect(done.summary).toContain("Server rollback: Published")
    expect(done.summary).toContain("Fly: success (published). Nuremberg: success (published).")
    const partial = rollback({ rollback_fly: { result: "success", outputs: { outcome: "published" } }, rollback_nuremberg: { result: "failure" } })
    expect(partial.summary).toContain("Server rollback: Failed")
    expect(partial.summary).toContain("Nuremberg: failure")
    const current = rollback({ rollback_fly: { result: "success", outputs: { outcome: "already-current" } } })
    expect(current.summary).toContain("Server rollback: Already current")
    const unavailable = rollback({ rollback_plan: { result: "failure" } })
    expect(unavailable.summary).toContain("rollback plan failure; no origin was changed")
    expect(unavailable.annotation).toContain("::error")
  })
})
