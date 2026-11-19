#!/usr/bin/env bun
// rollback_to_plan: find the most recent `server-release-plan` that a main
// release recorded before its migrations and replacements, and turn its
// pre-release baselines into immutable rollback targets.
//
// The plan's `fly` and `nuremberg` fields are the images each origin served
// before that release (preflight in server-deploy.yml). Rolling back to them
// undoes the latest release that reached an origin: a newer plan whose run
// never started a Fly or Nuremberg replacement (for example it failed at
// migrate) is skipped, because its baseline is still what is served. Rollback
// runs record no plan of their own, so a repeated rollback selects the same
// plan; the origin jobs then warn and stop when the baseline is already served.
// The workflow's run-level lock keeps any other deploy run from overlapping it.
//
// Env: GITHUB_REPOSITORY, GH_TOKEN, GITHUB_RUN_ID, ORIGINS (both|fly|nuremberg),
// PLAN_DIR, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY. The Nuremberg job re-checks the
// recorded baseline against its own Coolify app (nbg-release.ts --rollback).
// Optional PLAN_RUN_ID pins the release run whose plan to use.
import { appendFileSync, mkdirSync, readFileSync } from "node:fs"
import path from "node:path"
import { rollbackTarget } from "./nbg-release"

const SHA = /^[0-9a-f]{40}$/
const DIGEST = /^sha256:[0-9a-f]{64}$/
export const DEPLOY_WORKFLOW = ".github/workflows/server-deploy.yml"

export type Artifact = {
  id: number
  name: string
  expired: boolean
  created_at: string
  workflow_run?: { id?: number; head_branch?: string; head_sha?: string }
}

/** Unexpired plans recorded by main runs other than this one, newest first. */
export function planCandidates(artifacts: Artifact[], currentRunId: number, pinnedRunId?: number): Artifact[] {
  const candidates = artifacts
    .filter((artifact) => artifact.name === "server-release-plan" && !artifact.expired &&
      artifact.workflow_run?.head_branch === "main" && artifact.workflow_run.id !== currentRunId &&
      (pinnedRunId === undefined || artifact.workflow_run.id === pinnedRunId))
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.id - a.id)
  if (!candidates.length) {
    throw new Error(pinnedRunId === undefined
      ? "No unexpired server-release-plan from a main release exists; roll back manually (plans are kept for 90 days)"
      : `Run ${pinnedRunId} has no unexpired server-release-plan`)
  }
  return candidates
}

export type RunJob = { name: string; steps?: Array<{ name: string; status: string; conclusion: string | null }> }

// The steps in server-deploy.yml that change an origin.
export const ORIGIN_STEPS: Record<string, string> = {
  "Release and smoke-test the Nuremberg fallback": "Pin, deploy and verify the exact ARM64 image through Coolify",
  "Replace the public Machines and verify readiness": "Revalidate the recorded baseline and deploy the same digest",
}

/** Whether any attempt of a release run started replacing Fly or Nuremberg. */
export function reachedOrigin(jobs: RunJob[]): boolean {
  return jobs.some((job) => job.steps?.some((step) => ORIGIN_STEPS[job.name] === step.name &&
    step.status !== "queued" && step.status !== "pending" && step.conclusion !== "skipped"))
}

/** The newest plan whose release reached an origin, with notes for the newer plans passed over. */
export async function choosePlan(candidates: Artifact[], jobsFor: (runId: number) => Promise<RunJob[]>, pinned: boolean) {
  const notes: string[] = []
  for (const artifact of candidates.slice(0, 10)) {
    const runId = artifact.workflow_run!.id!
    if (reachedOrigin(await jobsFor(runId))) return { artifact, notes }
    if (pinned) {
      notes.push(`Run ${runId} never started replacing an origin; its baseline is probably what is already served.`)
      return { artifact, notes }
    }
    notes.push(`Skipped the plan of run ${runId}: that release never started replacing an origin.`)
  }
  throw new Error("None of the recent release plans belongs to a release that reached an origin; there is nothing to roll back. Pass rollback_plan_run to choose one.")
}


export type RollbackTargets = {
  planSha: string
  fly?: { image: string; revision: string }
  nuremberg?: { image: string; revision: string; baseline: Record<string, unknown> }
  notes: string[]
}

export function rollbackTargets(plan: unknown, origins: string): RollbackTargets {
  const value = plan !== null && typeof plan === "object" && !Array.isArray(plan) ? plan as Record<string, unknown> : {}
  if (value.schema !== 1 || typeof value.sha !== "string" || !SHA.test(value.sha)) throw new Error("The release plan is not a schema 1 plan")
  if (value.bootstrap !== false) throw new Error("A bootstrap plan has no routine baseline; roll back manually")
  if (!["both", "fly", "nuremberg"].includes(origins)) throw new Error("origins must be both, fly or nuremberg")
  const targets: RollbackTargets = { planSha: value.sha, notes: [] }
  if (origins !== "nuremberg") {
    const fly = value.fly as Record<string, unknown> | undefined
    if (!fly || typeof fly.digest !== "string" || !DIGEST.test(fly.digest) || typeof fly.revision !== "string" || !SHA.test(fly.revision)) {
      throw new Error("The release plan recorded no immutable Fly baseline")
    }
    targets.fly = { image: `ghcr.io/inline-chat/inline-server@${fly.digest}`, revision: fly.revision }
  }
  if (origins !== "fly") {
    if (value.nuremberg == null) {
      if (origins === "nuremberg") throw new Error("The release plan recorded no Nuremberg baseline (it was a Fly-only release)")
      targets.notes.push("The selected release was Fly-only; Nuremberg is left unchanged.")
    } else {
      const baseline = value.nuremberg as Record<string, unknown>
      try {
        targets.nuremberg = { ...rollbackTarget(baseline, String(baseline.app)), baseline }
      } catch (error) {
        // A Nuremberg problem must never hold back the Fly rollback.
        if (origins === "nuremberg") throw error
        targets.notes.push(`Nuremberg is left unchanged: ${error instanceof Error ? error.message : "its baseline is unusable"}.`)
      }
    }
  }
  return targets
}

async function listArtifacts(repository: string, token: string): Promise<Artifact[]> {
  const artifacts: Artifact[] = []
  for (let page = 1; page <= 3; page++) {
    const response = await fetch(`https://api.github.com/repos/${repository}/actions/artifacts?name=server-release-plan&per_page=100&page=${page}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" },
      signal: AbortSignal.timeout(20_000),
    })
    if (!response.ok) throw new Error(`GitHub API returned HTTP ${response.status} while listing release plans`)
    const body = await response.json() as { artifacts?: Artifact[] }
    if (!Array.isArray(body.artifacts)) throw new Error("GitHub API returned no artifact list")
    artifacts.push(...body.artifacts)
    if (body.artifacts.length < 100) break
  }
  return artifacts
}

async function api(repository: string, token: string, path: string): Promise<Record<string, unknown>> {
  const response = await fetch(`https://api.github.com/repos/${repository}/${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" },
    signal: AbortSignal.timeout(20_000),
  })
  if (!response.ok) throw new Error(`GitHub API returned HTTP ${response.status} for ${path.split("?")[0]}`)
  return await response.json() as Record<string, unknown>
}

if (import.meta.main) {
  try {
    const repository = process.env.GITHUB_REPOSITORY ?? ""
    const token = process.env.GH_TOKEN ?? ""
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) || !token) throw new Error("GITHUB_REPOSITORY and GH_TOKEN are required")
    const pinned = process.env.PLAN_RUN_ID ? Number(process.env.PLAN_RUN_ID) : undefined
    if (pinned !== undefined && !Number.isSafeInteger(pinned)) throw new Error("PLAN_RUN_ID must be a run id")
    const current = Number(process.env.GITHUB_RUN_ID)
    const candidates = planCandidates(await listArtifacts(repository, token), current, pinned)
    const { artifact, notes } = await choosePlan(candidates, async (id) =>
      ((await api(repository, token, `actions/runs/${id}/jobs?filter=all&per_page=100`)).jobs ?? []) as RunJob[], pinned !== undefined)
    const runId = artifact.workflow_run!.id!
    // Artifact names are not unique across workflows; require the release workflow.
    if (!String((await api(repository, token, `actions/runs/${runId}`)).path ?? "").startsWith(DEPLOY_WORKFLOW)) {
      throw new Error(`Run ${runId} is not a ${DEPLOY_WORKFLOW} run`)
    }
    const directory = process.env.PLAN_DIR!
    mkdirSync(directory, { recursive: true })
    const download = Bun.spawnSync(["gh", "run", "download", String(runId), "--repo", repository, "--name", "server-release-plan", "--dir", directory],
      { stdout: "inherit", stderr: "inherit" })
    if (download.exitCode !== 0) throw new Error(`Could not download the release plan of run ${runId}`)
    const plan = JSON.parse(readFileSync(path.join(directory, "release.json"), "utf8"))
    const targets = rollbackTargets(plan, process.env.ORIGINS ?? "both")
    targets.notes.unshift(...notes)
    for (const note of notes) console.log(`::warning title=Rollback plan::${note}`)
    const outputs = [
      `plan_run=${runId}`, `plan_sha=${targets.planSha}`,
      `fly=${Boolean(targets.fly)}`, `fly_image=${targets.fly?.image ?? ""}`, `fly_revision=${targets.fly?.revision ?? ""}`,
      `nuremberg=${Boolean(targets.nuremberg)}`, `nbg_baseline=${targets.nuremberg ? JSON.stringify(targets.nuremberg.baseline) : ""}`,
    ]
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${outputs.join("\n")}\n`)
    const server = process.env.GITHUB_SERVER_URL ?? "https://github.com"
    const lines = [
      "#### Rollback plan", "",
      `Undoing release \`${targets.planSha}\` using the plan recorded by [run ${runId}](${server}/${repository}/actions/runs/${runId}). Qualification and migrations are skipped.`, "",
      ...(targets.fly ? [`- Fly → \`${targets.fly.revision}\` at \`${targets.fly.image}\``] : ["- Fly: not selected"]),
      ...(targets.nuremberg ? [`- Nuremberg → \`${targets.nuremberg.revision}\` at \`${targets.nuremberg.image}\``] : ["- Nuremberg: not rolled back"]),
      ...targets.notes.map((note) => `- ${note}`),
    ]
    console.log(lines.join("\n"))
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.join("\n")}\n\n`)
  } catch (error) {
    const message = error instanceof Error ? error.message : "Rollback plan unavailable"
    console.log(`::error title=Rollback plan unavailable::${message}`)
    process.exitCode = 1
  }
}
