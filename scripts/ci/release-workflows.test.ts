import { describe, expect, it } from "bun:test"
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { parse } from "yaml"

const root = path.resolve(import.meta.dir, "../..")
type Step = { name?: string; run?: string; env?: Record<string, string>; with?: Record<string, unknown> }
const workflow = (name: string) => parse(readFileSync(path.join(root, ".github/workflows", name), "utf8")) as {
  jobs: Record<string, { steps: Step[] }>
}
describe("tag release workflow boundaries", () => {
  it("qualifies tags with trusted main before candidate code or publishing privileges", () => {
    for (const [file, job] of [["npm-publish.yml", "prepare"], ["cli-release.yml", "select"]]) {
      const parsed = workflow(file) as any
      const select = parsed.jobs[job!]
      const steps = select.steps as Step[]
      const gate = steps.findIndex((step) => step.run?.includes("scripts/ci/assert-release-commit.mjs"))
      expect(gate).toBeGreaterThan(0)
      expect(steps[0]?.with?.ref).toBe("main")
      expect(steps[0]?.with?.["persist-credentials"]).toBe(false)
      expect(select.environment).toBeUndefined()
      expect(parsed.permissions["id-token"]).toBeUndefined()
      for (const step of steps.slice(0, gate)) expect(step.run || "").not.toMatch(/\b(?:bun|npm) install\b/)
      expect(parsed.concurrency).toMatchObject({ "cancel-in-progress": false, queue: "max" })
    }
  })

  it("only the npm publisher gets OIDC and installs the checked artifact without lifecycle scripts", () => {
    const npm = workflow("npm-publish.yml") as any
    expect(npm.on.push.tags).toHaveLength(7)
    expect(npm.on.workflow_dispatch).toBeUndefined()
    expect(npm.jobs.publish.environment).toBe("npm-publish")
    expect(npm.jobs.publish.permissions["id-token"]).toBe("write")
    expect(npm.jobs.publish.needs).toBe("prepare")
    expect(npm.jobs.publish.concurrency).toMatchObject({ queue: "max", "cancel-in-progress": false })
    const source = npm.jobs.publish.steps.map((step: Step) => step.run || "").join("\n")
    expect(source).not.toMatch(/bun install|npm install(?! --global npm@)/)
    expect(source).toContain("scripts/ci/publish-npm-release.mjs")
    const steps = npm.jobs.prepare.steps as Step[]
    const dependencies = steps.findIndex((step) => step.run?.includes("bun install"))
    const metadata = steps.findIndex((step) => step.run?.includes("npm-release-preflight.mjs"))
    expect(metadata).toBeGreaterThan(-1)
    expect(dependencies).toBeGreaterThan(metadata)
    const install = steps.find((step) => step.name === "Install exact packed artifact outside the workspace")!
    expect(install.run).toContain('if [[ "$PACKAGE_KEY" == openclaw ]]')
    expect(install.run).toContain("devDependencies.openclaw")
    expect(install.run).toContain('"${host[@]}"')
    expect(npm.jobs.summary.needs).toEqual(["prepare", "publish"])
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
