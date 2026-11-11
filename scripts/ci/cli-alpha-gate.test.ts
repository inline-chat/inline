import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import path from "node:path"
import { parse } from "yaml"
import { CURRENT, DEFERRED, MIN_ALPHA_INTERVAL_MS, RELEASE, committedVersion, nextAlphaVersion, publishCliAlpha, selectCliAlpha } from "./cli-alpha-gate.mjs"

const root = path.resolve(import.meta.dir, "../..")
const sha = (char: string) => char.repeat(40)
const REPO = { full_name: "inline-chat/inline" }
const HOUR = 60 * 60 * 1000
const NOW = Date.parse("2026-11-11T12:00:00Z")
const CI_JOBS = ["Rust workspace all targets", "Workflow and release contracts"]
const UPDATE_JOBS = ["Update, drain, rollback and telemetry (ubuntu-24.04)", "Update, drain, rollback and telemetry (macos-26)"]

type Run = { id: number; status: string; conclusion?: string; jobs?: string[] }
type Options = {
  tags?: { tag: string; commit: string; taggedAt?: number }[]
  main: string[]
  ci?: Record<string, Run>
  cli?: Record<string, Run>
  releaseRuns?: { status: string }[]
  compare?: Record<string, string>
  version?: string
}

function fakeApi(options: Options) {
  const calls: { resource: string; method: string; body?: any }[] = []
  const runs = (map: Record<string, Run> = {}) => Object.entries(map).map(([head, run]) => ({
    id: run.id, status: run.status, conclusion: run.conclusion ?? "success", head_sha: head, head_branch: "main", event: "push", head_repository: REPO,
  }))
  const jobsFor = (id: number) => {
    const run = [...Object.values(options.ci ?? {}), ...Object.values(options.cli ?? {})].find((entry) => entry.id === id)!
    const names = run.jobs ?? (Object.values(options.ci ?? {}).includes(run) ? CI_JOBS : UPDATE_JOBS)
    return { jobs: names.map((name) => ({ name, status: "completed", conclusion: run.conclusion ?? "success" })) }
  }
  const api = (resource: string, { method = "GET", body, missingOk = false }: { method?: string; body?: any; missingOk?: boolean } = {}) => {
    calls.push({ resource, method, body })
    if (resource === "git/matching-refs/tags/cli-v") {
      return (options.tags ?? []).map(({ tag }) => ({ ref: `refs/tags/${tag}`, object: { type: "tag", sha: `tagobj-${tag}` } }))
    }
    if (resource.startsWith("git/tags/tagobj-")) {
      const entry = options.tags!.find(({ tag }) => resource === `git/tags/tagobj-${tag}`)!
      return { tagger: { date: new Date(entry.taggedAt ?? NOW - 24 * HOUR).toISOString() }, object: { type: "commit", sha: entry.commit } }
    }
    if (resource.startsWith("git/ref/tags/")) {
      const entry = options.tags?.find(({ tag }) => resource === `git/ref/tags/${tag}`)
      if (!entry && missingOk) return null
      return { object: { type: "tag", sha: `tagobj-${entry!.tag}` } }
    }
    if (resource === "git/tags" && method === "POST") return { sha: "new-tag-object" }
    if (resource === "git/refs" && method === "POST") return { ref: body.ref }
    if (resource.endsWith("/dispatches")) return null
    if (resource.startsWith("actions/workflows/cli-release.yml/runs")) return { workflow_runs: options.releaseRuns ?? [] }
    if (resource.startsWith("actions/workflows/integrations.yml/runs")) {
      const head = /head_sha=([0-9a-f]{40})/.exec(resource)?.[1]
      return { workflow_runs: runs(options.ci).filter((run) => !head || run.head_sha === head) }
    }
    if (resource.startsWith("actions/workflows/cli-update-qualification.yml/runs")) {
      const head = /head_sha=([0-9a-f]{40})/.exec(resource)?.[1]
      return { workflow_runs: runs(options.cli).filter((run) => !head || run.head_sha === head) }
    }
    const jobs = /^actions\/runs\/(\d+)\/jobs/.exec(resource)
    if (jobs) return jobsFor(Number(jobs[1]))
    if (resource.startsWith("commits?sha=main")) return options.main.map((value) => ({ sha: value }))
    const compare = /^compare\/([0-9a-f]{40})\.\.\.([0-9a-f]{40})$/.exec(resource)
    if (compare) return { status: options.compare?.[`${compare[1]}...${compare[2]}`] ?? "ahead" }
    if (resource.startsWith("contents/Cargo.toml")) {
      const toml = `[workspace]\nmembers = ["cli"]\n\n[workspace.package]\nauthors = ["Inline"]\nversion = "${options.version ?? "0.7.22-alpha.4"}"\n`
      return { encoding: "base64", content: Buffer.from(toml).toString("base64") }
    }
    throw new Error(`Unexpected API call: ${method} ${resource}`)
  }
  return { api, calls }
}

const green = (id: number): Run => ({ id, status: "completed" })
const tagged = (hoursAgo = 24) => [{ tag: "cli-v0.7.22-alpha.4", commit: sha("1"), taggedAt: NOW - hoursAgo * HOUR }]

describe("CLI alpha versions", () => {
  test("continues the newest alpha or starts the next patch's alphas after a stable", () => {
    expect(nextAlphaVersion(["0.7.21", "0.7.22-alpha.3", "0.7.22-alpha.4"], "0.7.22-alpha.4")).toBe("0.7.22-alpha.5")
    expect(nextAlphaVersion(["0.7.22-alpha.9", "0.7.22-alpha.10"], "0.7.22-alpha.3")).toBe("0.7.22-alpha.11")
    expect(nextAlphaVersion(["0.7.22-alpha.4", "0.7.22"], "0.7.22")).toBe("0.7.23-alpha.1")
    // An untagged version commit (a manual release still in CI) is never reused.
    expect(nextAlphaVersion(["0.7.22-alpha.4"], "0.7.23-alpha.1")).toBe("0.7.23-alpha.2")
    expect(() => nextAlphaVersion(["0.7.23-beta.1"], "0.7.22")).toThrow("release:cli")
  })

  test("reads the committed workspace version past other workspace fields", () => {
    const { api } = fakeApi({ main: [], version: "0.7.30-alpha.2" })
    expect(committedVersion(api, sha("a"))).toBe("0.7.30-alpha.2")
  })
})

describe("CLI alpha selection", () => {
  test("tags the newest green CLI change above the last tag", () => {
    const { api } = fakeApi({ tags: tagged(), main: [sha("c"), sha("b"), sha("1")], ci: { [sha("c")]: green(3), [sha("b")]: green(2) }, cli: { [sha("b")]: green(12) } })
    expect(selectCliAlpha({ api, event: "schedule", now: NOW })).toMatchObject({
      sha: sha("b"), outcome: RELEASE, tag: "cli-v0.7.22-alpha.5", version: "0.7.22-alpha.5",
    })
  })

  test("waits on a CI completion while a newer CLI change is still running, but the sweep releases", () => {
    const options = { tags: tagged(), main: [sha("c"), sha("b"), sha("1")], ci: { [sha("c")]: { id: 3, status: "in_progress" }, [sha("b")]: green(2) }, cli: { [sha("c")]: green(13), [sha("b")]: green(12) } }
    expect(selectCliAlpha({ api: fakeApi(options).api, event: "workflow_run", now: NOW })).toMatchObject({ outcome: DEFERRED, sha: sha("c") })
    expect(selectCliAlpha({ api: fakeApi(options).api, event: "schedule", now: NOW })).toMatchObject({ outcome: RELEASE, sha: sha("b") })
  })

  test("skips red CLI changes and never walks past the last tagged commit", () => {
    const { api } = fakeApi({ tags: tagged(), main: [sha("c"), sha("1"), sha("0")], ci: { [sha("c")]: { id: 3, status: "completed", conclusion: "failure" }, [sha("0")]: green(1) }, cli: { [sha("c")]: green(13), [sha("0")]: green(10) } })
    expect(selectCliAlpha({ api, event: "schedule", now: NOW })).toMatchObject({ outcome: CURRENT })
  })

  test("is already current when no CLI change landed since the last tag", () => {
    const { api } = fakeApi({ tags: tagged(), main: [sha("c"), sha("1")], ci: { [sha("c")]: green(3) } })
    expect(selectCliAlpha({ api, event: "workflow_run", now: NOW })).toMatchObject({ outcome: CURRENT })
  })

  test("defers inside the interval except for a manual run", () => {
    const options = { tags: tagged(1), main: [sha("b"), sha("1")], ci: { [sha("b")]: green(2) }, cli: { [sha("b")]: green(12) } }
    expect(selectCliAlpha({ api: fakeApi(options).api, event: "schedule", now: NOW }).outcome).toBe(DEFERRED)
    expect(selectCliAlpha({ api: fakeApi(options).api, event: "workflow_dispatch", now: NOW }).outcome).toBe(RELEASE)
    expect(MIN_ALPHA_INTERVAL_MS).toBe(3 * HOUR)
  })

  test("never stacks releases on a running CLI Release", () => {
    const { api } = fakeApi({ tags: tagged(), main: [sha("b"), sha("1")], releaseRuns: [{ status: "queued" }] })
    expect(selectCliAlpha({ api, event: "workflow_dispatch", now: NOW })).toMatchObject({ outcome: DEFERRED, reason: "a CLI release is already running" })
  })
})

describe("CLI alpha publication", () => {
  test("creates an annotated tag on the selected commit, then dispatches CLI Release from main", () => {
    const { api, calls } = fakeApi({ tags: tagged(), main: [] })
    publishCliAlpha({ api, sha: sha("b"), tag: "cli-v0.7.22-alpha.5", version: "0.7.22-alpha.5" })
    const writes = calls.filter((call) => call.method === "POST")
    expect(writes.map((call) => call.resource)).toEqual(["git/tags", "git/refs", "actions/workflows/cli-release.yml/dispatches"])
    expect(writes[0]!.body).toMatchObject({ tag: "cli-v0.7.22-alpha.5", object: sha("b"), type: "commit" })
    expect(writes[1]!.body).toEqual({ ref: "refs/tags/cli-v0.7.22-alpha.5", sha: "new-tag-object" })
    expect(writes[2]!.body).toEqual({ ref: "main", inputs: { tag: "cli-v0.7.22-alpha.5" } })
  })

  test("resumes an existing tag on the same commit and refuses one on another commit", () => {
    const existing = { tags: [{ tag: "cli-v0.7.22-alpha.5", commit: sha("b") }], main: [] }
    const same = fakeApi(existing)
    publishCliAlpha({ api: same.api, sha: sha("b"), tag: "cli-v0.7.22-alpha.5", version: "0.7.22-alpha.5" })
    expect(same.calls.filter((call) => call.method === "POST").map((call) => call.resource)).toEqual(["actions/workflows/cli-release.yml/dispatches"])
    expect(() => publishCliAlpha({ api: fakeApi(existing).api, sha: sha("c"), tag: "cli-v0.7.22-alpha.5", version: "0.7.22-alpha.5" })).toThrow("another commit")
  })

  test("reports a tag ruleset refusal as blocked with the fix", () => {
    const { api } = fakeApi({ main: [] })
    const refusing = (resource: string, options: any = {}) => {
      if (resource === "git/refs") throw Object.assign(new Error("gh failed"), { stderr: "gh: Reference update failed (HTTP 422)" })
      return api(resource, options)
    }
    let error: any
    try { publishCliAlpha({ api: refusing, sha: sha("b"), tag: "cli-v0.7.22-alpha.5", version: "0.7.22-alpha.5" }) } catch (caught) { error = caught }
    expect(error.outcome).toBe("blocked")
    expect(error.message).toContain("Release tags: admin creation")
  })

  test("only publishes alpha tags", () => {
    const { api } = fakeApi({ main: [] })
    for (const version of ["0.7.22", "0.7.22-beta.1"]) {
      expect(() => publishCliAlpha({ api, sha: sha("b"), tag: `cli-v${version}`, version })).toThrow()
    }
  })
})

describe("CLI alpha workflow boundaries", () => {
  const workflow = parse(readFileSync(path.join(root, ".github/workflows/cli-alpha.yml"), "utf8")) as any

  test("runs trusted main tools without release environments or secrets", () => {
    expect(workflow.on.workflow_run).toMatchObject({ workflows: ["CI", "CLI Update Qualification"], branches: ["main"] })
    expect(workflow.concurrency).toMatchObject({ group: "cli-alpha", "cancel-in-progress": false })
    expect(workflow.permissions).toEqual({ contents: "read" })
    const job = workflow.jobs.release
    expect(job.environment).toBeUndefined()
    expect(job.permissions).toEqual({ actions: "write", contents: "write" })
    expect(job.if).toContain("refs/heads/main")
    expect(job.steps[0].with).toEqual({ ref: "main", "persist-credentials": false })
    const source = JSON.stringify(job.steps)
    expect(source).not.toContain("secrets.")
    expect(source).not.toMatch(/bun install|npm install/)
    for (const step of job.steps) if (step.uses) expect(step.uses).toMatch(/@[a-f0-9]{40}$/)
  })

  test("names the workflows that actually exist", () => {
    for (const [file, name] of [["integrations.yml", "CI"], ["cli-update-qualification.yml", "CLI Update Qualification"]]) {
      expect((parse(readFileSync(path.join(root, ".github/workflows", file), "utf8")) as any).name).toBe(name)
    }
  })
})

describe("CLI alpha outcomes", () => {
  const workflow = parse(readFileSync(path.join(root, ".github/workflows/cli-alpha.yml"), "utf8")) as any
  const script = workflow.jobs.release.steps.find((step: any) => step.name?.startsWith("Report")).run
  const report = (env: Record<string, string>) => {
    const result = Bun.spawnSync(["bash", "-e", "-c", script], { cwd: root, env: { ...process.env, GITHUB_STEP_SUMMARY: "/dev/null", SHA: sha("b"), TAG: "cli-v0.7.22-alpha.5", ...env } })
    return { exitCode: result.exitCode, annotation: result.stdout.toString() }
  }

  test("reports a ruleset refusal as blocked with its fix, and only a dispatch as tagged", () => {
    const blocked = report({ GATE_RESULT: "success", SHOULD_RELEASE: "true", GATE_OUTCOME: "release", REASON: "selected", PUBLISH_RESULT: "failure", PUBLISH_OUTCOME: "blocked", PUBLISH_REASON: "add it to the bypass list" })
    expect(blocked.annotation).toContain("CLI Alpha: Blocked — add it to the bypass list")
    const failed = report({ GATE_RESULT: "success", SHOULD_RELEASE: "true", GATE_OUTCOME: "release", REASON: "selected", PUBLISH_RESULT: "failure", PUBLISH_OUTCOME: "failed", PUBLISH_REASON: "" })
    expect(failed.annotation).toContain("CLI Alpha: Failed")
    const tagged = report({ GATE_RESULT: "success", SHOULD_RELEASE: "true", GATE_OUTCOME: "release", REASON: "selected", PUBLISH_RESULT: "success", PUBLISH_OUTCOME: "", PUBLISH_REASON: "" })
    expect(tagged.annotation).toContain("tagged cli-v0.7.22-alpha.5; CLI Release builds and publishes it")
    expect(tagged.annotation).not.toContain("Published")
    const current = report({ GATE_RESULT: "success", SHOULD_RELEASE: "false", GATE_OUTCOME: "already-current", REASON: "nothing new", PUBLISH_RESULT: "skipped", PUBLISH_OUTCOME: "", PUBLISH_REASON: "" })
    expect(current.annotation).toContain("Already current — nothing new")
  })
})
