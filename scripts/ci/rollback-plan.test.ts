import { describe, expect, it } from "bun:test"
import { choosePlan, planCandidates, reachedOrigin, rollbackTargets, type Artifact, type RunJob } from "./rollback-plan"

const sha = "a".repeat(40)
const old = "c".repeat(40)
const digest = `sha256:${"3".repeat(64)}`
const plan = {
  schema: 1, sha, runtime_image: "ignored", standby_image: "ignored", migration_head: "0200_x", origins: "both", bootstrap: false,
  fly: { count: 1, ids: "m1", digest, revision: old },
  nuremberg: { app: "app1", imageName: "ghcr.io/inline-chat/inline-server@sha256", imageTag: "4".repeat(64), revision: old },
}
const artifact = (id: number, run: number, created: string, extra: Partial<Artifact> = {}): Artifact =>
  ({ id, name: "server-release-plan", expired: false, created_at: created, workflow_run: { id: run, head_branch: "main" }, ...extra })

describe("rollback plan selection", () => {
  it("lists unexpired main plans other than this run, newest first, or a pinned run", () => {
    const artifacts = [
      artifact(1, 10, "2026-11-10T00:00:00Z"),
      artifact(2, 11, "2026-11-12T00:00:00Z"),
      artifact(3, 12, "2026-11-13T00:00:00Z", { expired: true }),
      artifact(4, 13, "2026-11-14T00:00:00Z", { workflow_run: { id: 13, head_branch: "feature" } }),
      artifact(5, 14, "2026-11-15T00:00:00Z", { name: "nbg-release-state-1" }),
      artifact(6, 99, "2026-11-16T00:00:00Z"),
    ]
    expect(planCandidates(artifacts, 99).map((a) => a.id)).toEqual([2, 1])
    expect(planCandidates(artifacts, 99, 10).map((a) => a.id)).toEqual([1])
    expect(() => planCandidates(artifacts, 99, 12)).toThrow("Run 12 has no unexpired")
    expect(() => planCandidates([], 99)).toThrow("roll back manually")
  })

  const deployJob = (conclusion: string | null, status = "completed"): RunJob => ({ name: "Replace the public Machines and verify readiness",
    steps: [{ name: "Revalidate the recorded baseline and deploy the same digest", status, conclusion }] })
  const nbgJob = (conclusion: string | null): RunJob => ({ name: "Release and smoke-test the Nuremberg fallback",
    steps: [{ name: "Pin, deploy and verify the exact ARM64 image through Coolify", status: "completed", conclusion }] })

  it("counts a release as reaching an origin once a replacement step started, even if it then failed", () => {
    expect(reachedOrigin([deployJob("success")])).toBe(true)
    expect(reachedOrigin([deployJob("failure")])).toBe(true)
    expect(reachedOrigin([nbgJob("failure")])).toBe(true)
    expect(reachedOrigin([deployJob("skipped"), nbgJob("skipped")])).toBe(false)
    expect(reachedOrigin([deployJob(null, "queued")])).toBe(false)
    expect(reachedOrigin([{ name: "Migrate and verify with the qualified image", steps: [{ name: "Apply and verify the migration ledger", status: "completed", conclusion: "failure" }] }])).toBe(false)
    expect(reachedOrigin([])).toBe(false)
  })

  it("passes over a newer release that never reached an origin (failed at migrate, baseline still served)", async () => {
    const candidates = [artifact(2, 20, "2026-11-12T00:00:00Z"), artifact(1, 10, "2026-11-10T00:00:00Z")]
    const jobs: Record<number, RunJob[]> = { 20: [deployJob("skipped")], 10: [nbgJob("success"), deployJob("success")] }
    const chosen = await choosePlan(candidates, async (id) => jobs[id]!, false)
    expect(chosen.artifact.id).toBe(1)
    expect(chosen.notes).toEqual(["Skipped the plan of run 20: that release never started replacing an origin."])
    const pinned = await choosePlan([candidates[0]!], async (id) => jobs[id]!, true)
    expect(pinned.artifact.id).toBe(2)
    expect(pinned.notes[0]).toContain("never started replacing an origin")
    await expect(choosePlan([candidates[0]!], async (id) => jobs[id]!, false)).rejects.toThrow("nothing to roll back")
  })

  it("turns the recorded pre-release baselines into immutable targets per selected origin", () => {
    expect(rollbackTargets(plan, "both")).toEqual({
      planSha: sha, notes: [],
      fly: { image: `ghcr.io/inline-chat/inline-server@${digest}`, revision: old },
      nuremberg: { image: `ghcr.io/inline-chat/inline-server@sha256:${"4".repeat(64)}`, revision: old, baseline: plan.nuremberg },
    })
    expect(rollbackTargets(plan, "fly").nuremberg).toBeUndefined()
    expect(rollbackTargets(plan, "nuremberg").fly).toBeUndefined()
    const flyOnly = rollbackTargets({ ...plan, origins: "fly", nuremberg: null }, "both")
    expect(flyOnly.nuremberg).toBeUndefined()
    expect(flyOnly.notes).toEqual(["The selected release was Fly-only; Nuremberg is left unchanged."])
  })

  it("refuses plans it cannot roll back safely", () => {
    expect(() => rollbackTargets({ ...plan, bootstrap: true }, "both")).toThrow("bootstrap")
    expect(() => rollbackTargets({ ...plan, schema: 2 }, "both")).toThrow("schema 1")
    expect(() => rollbackTargets({ ...plan, fly: { ...plan.fly, digest: "latest" } }, "fly")).toThrow("immutable Fly baseline")
    expect(() => rollbackTargets({ ...plan, nuremberg: null }, "nuremberg")).toThrow("Fly-only")
    const legacy = { ...plan, nuremberg: { ...plan.nuremberg, imageName: "127.0.0.1:5000/inline-api" } }
    expect(() => rollbackTargets(legacy, "nuremberg")).toThrow("manually")
    // ...but it never blocks the Fly rollback.
    const both = rollbackTargets(legacy, "both")
    expect(both.fly).toBeDefined()
    expect(both.nuremberg).toBeUndefined()
    expect(both.notes[0]).toContain("Nuremberg is left unchanged")
    expect(() => rollbackTargets(plan, "all")).toThrow("origins")
  })
})
