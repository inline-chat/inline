import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { parse } from "yaml"

const root = path.resolve(import.meta.dir, "../..")
type Step = { name?: string; run?: string; env?: Record<string, string>; with?: Record<string, unknown> }
const workflow = (name: string) => parse(readFileSync(path.join(root, ".github/workflows", name), "utf8")) as {
  jobs: Record<string, { steps: Step[] }>
}
const npm = workflow("npm-publish.yml").jobs.publish.steps
const cli = workflow("cli-release.yml").jobs
const sourceGates = [
  { label: "npm", steps: npm },
  { label: "CLI preflight", steps: cli.preflight.steps },
  { label: "CLI validation", steps: cli.validate.steps },
].map(({ label, steps }) => {
  const index = steps.findIndex((step) => step.env?.RELEASE_COMMIT && step.run?.includes("merge-base --is-ancestor"))
  if (index < 0) throw new Error(`${label} has no source validation step`)
  return { label, steps, index, script: steps[index].run! }
})

describe("release source validation", () => {
  let directory: string
  let checkout: string
  let candidate: string
  let newer: string
  let offMain: string
  const gitEnv = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_TERMINAL_PROMPT: "0" }
  const git = (cwd: string, ...args: string[]) => {
    const result = Bun.spawnSync(["git", ...args], { cwd, env: gitEnv })
    if (result.exitCode !== 0) throw new Error(result.stderr.toString())
    return result.stdout.toString().trim()
  }

  beforeAll(() => {
    directory = mkdtempSync(path.join(tmpdir(), "inline-release-gates-"))
    const origin = path.join(directory, "origin.git")
    const source = path.join(directory, "source")
    checkout = path.join(directory, "checkout")
    git(directory, "init", "--bare", "--initial-branch=main", origin)
    git(directory, "init", "--initial-branch=main", source)
    git(source, "config", "user.name", "Release fixture")
    git(source, "config", "user.email", "release-fixture@example.invalid")
    git(source, "config", "core.hooksPath", "/dev/null")
    git(source, "remote", "add", "origin", origin)
    const commit = (content: string) => {
      writeFileSync(path.join(source, "source.txt"), content)
      git(source, "add", "source.txt")
      git(source, "commit", "-m", content)
      return git(source, "rev-parse", "HEAD")
    }
    candidate = commit("selected release")
    newer = commit("main advanced")
    git(source, "push", "origin", "main")
    git(source, "checkout", "-b", "off-main", candidate)
    offMain = commit("unqualified branch")
    git(source, "push", "origin", "off-main")
    git(directory, "clone", origin, checkout)
  }, 15_000)

  afterAll(() => { if (directory) rmSync(directory, { recursive: true, force: true }) })

  for (const gate of sourceGates) {
    it(`${gate.label} accepts the selected commit after main advances`, () => {
      git(checkout, "checkout", "--detach", candidate)
      const result = Bun.spawnSync(["bash", "-e", "-c", gate.script], {
        cwd: checkout, env: { ...gitEnv, RELEASE_COMMIT: candidate },
      })
      expect(result.exitCode, result.stderr.toString()).toBe(0)
      expect(git(checkout, "rev-parse", "origin/main")).toBe(newer)
    })

    it(`${gate.label} rejects off-main, mismatched and malformed candidates before proceeding`, () => {
      const marker = path.join(directory, "validated")
      for (const [head, requested] of [[offMain, offMain], [candidate, newer], [candidate, "main"]]) {
        git(checkout, "checkout", "--detach", head!)
        const result = Bun.spawnSync(["bash", "-e", "-c", `${gate.script}\nprintf validated > "$MARKER"`], {
          cwd: checkout, env: { ...gitEnv, RELEASE_COMMIT: requested!, MARKER: marker },
        })
        expect(result.exitCode).not.toBe(0)
        expect(existsSync(marker)).toBe(false)
      }
    })
  }

  it("validates npm source immediately after checkout and before any dependency installation", () => {
    const gate = sourceGates[0]!
    expect(gate.index).toBe(1)
    expect(npm[0]?.with?.ref).toBe("${{ inputs.commit }}")
    const installs = npm.flatMap((step, index) => /\b(?:bun|npm) install\b/.test(step.run || "") ? [index] : [])
    expect(installs.length).toBeGreaterThan(0)
    for (const index of installs) expect(index).toBeGreaterThan(gate.index)
  })
})

describe("Apple release outcomes", () => {
  const sha = "a".repeat(40)
  const mac = workflow("macos-tip-nightly.yml").jobs.summary.steps.find((step) => step.run)!.run!
  const ios = workflow("ios-early-testers.yml").jobs.release.steps.find((step) => step.name?.startsWith("Report published"))!.run!
  const report = (script: string, env: Record<string, string>) => {
    const directory = mkdtempSync(path.join(tmpdir(), "inline-release-outcome-"))
    const summary = path.join(directory, "summary.md")
    try {
      const result = Bun.spawnSync(["bash", "-e", "-c", script], {
        cwd: root, env: { ...process.env, SHA: sha, GITHUB_STEP_SUMMARY: summary, ...env },
      })
      return { exitCode: result.exitCode, annotation: result.stdout.toString(), summary: existsSync(summary) ? readFileSync(summary, "utf8") : "" }
    } finally {
      rmSync(directory, { recursive: true, force: true })
    }
  }

  for (const [outcome, label] of [["already-current", "Already current"], ["deferred", "Deferred"], ["blocked", "Blocked"]]) {
    it(`reports ${outcome} when the publisher is skipped`, () => {
      for (const [script, env] of [
        [mac, { SELECT_RESULT: "success", RELEASE_RESULT: "skipped", SHOULD_RELEASE: "false", OUTCOME: outcome, REASON: "candidate gate reason" }],
        [ios, { GATE_RESULT: "success", PUBLISH_RESULT: "skipped", SHOULD_RELEASE: "false", GATE_OUTCOME: outcome, REASON: "candidate gate reason", PUBLISH_OUTCOME: "", BUILD: "" }],
      ] as const) {
        const result = report(script, env)
        expect(result.exitCode).toBe(0)
        expect(result.summary).toContain(`: ${label} — candidate gate reason`)
        expect(result.summary).toContain(sha)
        expect(result.summary).not.toContain(": Published")
        expect(result.annotation).toContain(outcome === "blocked" ? "::error" : "::notice")
      }
    })
  }

  it("reports publication only after the publishing job succeeds", () => {
    const macResult = report(mac, { SELECT_RESULT: "success", RELEASE_RESULT: "success", SHOULD_RELEASE: "true", OUTCOME: "release", REASON: "selected" })
    expect(macResult.exitCode).toBe(0)
    expect(macResult.summary).toContain("macOS tip: Published")
    for (const outcome of ["published", "already-current"]) {
      const result = report(ios, { GATE_RESULT: "success", PUBLISH_RESULT: "success", SHOULD_RELEASE: "true", GATE_OUTCOME: "release", REASON: "selected", PUBLISH_OUTCOME: outcome, BUILD: "42" })
      expect(result.exitCode).toBe(0)
      expect(result.summary).toContain(outcome === "published" ? "iOS Early Testers: Published" : "iOS Early Testers: Already current")
      expect(result.summary).toContain("Build 42")
    }
  })

  it("reports selection and publishing failures without claiming a release", () => {
    for (const [script, env] of [
      [mac, { SELECT_RESULT: "failure", RELEASE_RESULT: "skipped", SHOULD_RELEASE: "", OUTCOME: "", REASON: "" }],
      [mac, { SELECT_RESULT: "success", RELEASE_RESULT: "failure", SHOULD_RELEASE: "true", OUTCOME: "release", REASON: "selected" }],
      [ios, { GATE_RESULT: "failure", PUBLISH_RESULT: "skipped", SHOULD_RELEASE: "", GATE_OUTCOME: "", REASON: "", PUBLISH_OUTCOME: "", BUILD: "" }],
      [ios, { GATE_RESULT: "success", PUBLISH_RESULT: "failure", SHOULD_RELEASE: "true", GATE_OUTCOME: "release", REASON: "selected", PUBLISH_OUTCOME: "", BUILD: "" }],
    ] as const) {
      const result = report(script, env)
      expect(result.exitCode).toBe(0)
      expect(result.summary).toContain(": Failed —")
      expect(result.annotation).toContain("::error")
      expect(result.summary).not.toContain(": Published")
      expect(result.summary).not.toContain("resumes the same")
    }
  })
})
