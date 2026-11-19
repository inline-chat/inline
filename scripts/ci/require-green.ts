#!/usr/bin/env bun
// Soft deploy gate: the server-relevant checks of the commit being released
// must be green. There is no branch protection; this only stops an ordinary
// dispatch of a red commit, and skip_gate (with a recorded reason) always
// bypasses it in the workflow without running this script.
//
// It gates on these jobs only, read from the push runs of the exact commit
// (jobs API, latest attempt of each run):
//
//   Server Tests (server-test.yml), deferrable:
//     - Server Typecheck, Lint, and Tests
//     - Server Linux image and migration commands
//     - Server ARM64 Coolify image and runtime
//   CI (integrations.yml), required:
//     - Shared TypeScript packages            (protocol, oauth-core, bot-api-types the server imports)
//     - Packed adapters with local Inline server  (source server end to end with Bot HTTP, SDK and MCP clients)
//
// The rest of CI (Apple, Rust, OpenClaw/Hermes hosts, catalog parity, workflow
// contracts) does not gate server deploys. A failed gated job fails the gate
// immediately; a queued or running one is awaited for at most WAIT_MINUTES,
// about qualify's duration, because the deploy run holds the production lock
// while it waits and an incident dispatch queues behind it. A Server Tests job that was
// cancelled (main pushes cancel superseded runs), is missing or still running
// is deferred: this deploy's qualify job reruns Server Tests on the same
// commit before any production job. A skipped CI job means its dependency
// failed, so it fails the gate.
//
// Env: GITHUB_REPOSITORY, RELEASE_SHA, GH_TOKEN; ROLLBACK and PUBLISH_ONLY
// ("true"/"false").
// Usage: require-green.ts [--wait]
import { appendFileSync } from "node:fs"

export type WorkflowRun = { id: number; head_sha: string; status: string; conclusion: string | null; html_url: string }
export type WorkflowJob = { name: string; status: string; conclusion: string | null; html_url?: string }
export type Gate = { workflow: string; file: string; deferrable: boolean; jobs: string[] }
export type Verdict = { name: string; state: "green" | "pending" | "red" | "deferred"; detail: string; url?: string }
export type Fetcher = { runs(file: string): Promise<WorkflowRun[]>; jobs(runId: number): Promise<WorkflowJob[]> }

export const GATES: Gate[] = [
  { workflow: "Server Tests", file: "server-test.yml", deferrable: true, jobs: [
    "Server Typecheck, Lint, and Tests",
    "Server Linux image and migration commands",
    "Server ARM64 Coolify image and runtime",
  ] },
  { workflow: "CI", file: "integrations.yml", deferrable: false, jobs: [
    "Shared TypeScript packages",
    "Packed adapters with local Inline server",
  ] },
]

const SHA = /^[0-9a-f]{40}$/
/** Longest wait for running gated jobs; keep it near qualify's duration. */
export const WAIT_MINUTES = 15
const defer = "this deploy's qualify job reruns Server Tests on this commit"

/** One gated job across every push run of the commit (newest run first). */
export function judgeJob(gate: Gate, name: string, runs: Array<{ run: WorkflowRun; jobs: WorkflowJob[] }>): Verdict {
  const label = `${gate.workflow}: ${name}`
  const found = runs.flatMap(({ run, jobs }) => jobs.filter((job) => job.name === name).map((job) => ({ run, job })))
  const success = found.find(({ job }) => job.status === "completed" && job.conclusion === "success")
  if (success) return { name: label, state: "green", detail: `passed in run ${success.run.id}`, url: success.job.html_url ?? success.run.html_url }
  const failure = found.find(({ job }) => job.status === "completed" &&
    !["success", "cancelled", "skipped", "neutral"].includes(job.conclusion ?? ""))
  if (failure) return { name: label, state: "red", detail: `${failure.job.conclusion} in run ${failure.run.id}`, url: failure.job.html_url ?? failure.run.html_url }
  // A job appears only once its run schedules it, so an unfinished run without it is still pending.
  const active = found.find(({ job }) => job.status !== "completed") ?? runs.find(({ run, jobs }) =>
    run.status !== "completed" && !jobs.some((job) => job.name === name))
  if (gate.deferrable) {
    const latest = found[0]
    const state = latest ? latest.job.status === "completed" ? latest.job.conclusion : latest.job.status : "not run"
    return { name: label, state: "deferred", detail: `${state}; ${defer}`, ...(latest ? { url: latest.job.html_url ?? latest.run.html_url } : {}) }
  }
  if (active) return { name: label, state: "pending", detail: `waiting for run ${active.run.id}`, url: active.run.html_url }
  const skipped = found.find(({ job }) => job.conclusion === "skipped")
  if (skipped) return { name: label, state: "red", detail: `skipped in run ${skipped.run.id} (a dependency failed)`, url: skipped.run.html_url }
  const cancelled = found[0]
  if (cancelled) return { name: label, state: "pending", detail: `cancelled in run ${cancelled.run.id}; waiting for a rerun`, url: cancelled.run.html_url }
  if (runs.length) {
    return { name: label, state: "red", detail: `no job named "${name}" in run ${runs[0]!.run.id}; update GATES in scripts/ci/require-green.ts`, url: runs[0]!.run.html_url }
  }
  return { name: label, state: "pending", detail: "no push run yet for this commit" }
}

export async function evaluate(options: {
  sha: string
  fetch: Fetcher
  wait?: boolean
  deadlineMs?: number
  pause?: (ms: number) => Promise<void>
  now?: () => number
  log?: (line: string) => void
}): Promise<{ ok: boolean; verdicts: Verdict[] }> {
  if (!SHA.test(options.sha)) throw new Error("RELEASE_SHA must be a full commit SHA")
  const now = options.now ?? Date.now
  const deadline = now() + (options.deadlineMs ?? WAIT_MINUTES * 60_000)
  const pause = options.pause ?? Bun.sleep
  for (;;) {
    const verdicts: Verdict[] = []
    for (const gate of GATES) {
      const runs = (await options.fetch.runs(gate.file)).filter((run) => run.head_sha === options.sha).sort((a, b) => b.id - a.id)
      const withJobs = []
      for (const run of runs) withJobs.push({ run, jobs: await options.fetch.jobs(run.id) })
      for (const name of gate.jobs) verdicts.push(judgeJob(gate, name, withJobs))
    }
    if (verdicts.some((verdict) => verdict.state === "red")) return { ok: false, verdicts }
    if (!verdicts.some((verdict) => verdict.state === "pending")) return { ok: true, verdicts }
    if (!options.wait || now() >= deadline) return { ok: false, verdicts }
    options.log?.(verdicts.filter((verdict) => verdict.state === "pending").map((verdict) => `${verdict.name}: ${verdict.detail}`).join("; "))
    await pause(30_000)
  }
}

export function githubFetcher(repository: string, sha: string, token: string, fetcher: typeof fetch = fetch): Fetcher {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) throw new Error("GITHUB_REPOSITORY is invalid")
  if (!token) throw new Error("GH_TOKEN is required")
  const get = async (path: string) => {
    let response: Response
    try {
      response = await fetcher(`https://api.github.com/repos/${repository}/${path}`, { headers: { Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" }, signal: AbortSignal.timeout(20_000) })
    } catch { throw new Error(`GitHub API request for ${path.split("?")[0]} failed; rerun this job or dispatch with skip_gate`) }
    if (!response.ok) throw new Error(`GitHub API returned HTTP ${response.status} for ${path.split("?")[0]}; rerun this job or dispatch with skip_gate`)
    return await response.json() as Record<string, unknown>
  }
  return {
    async runs(file) {
      const body = await get(`actions/workflows/${file}/runs?head_sha=${sha}&event=push&per_page=20`)
      if (!Array.isArray(body.workflow_runs)) throw new Error(`GitHub API returned no workflow runs for ${file}`)
      return body.workflow_runs as WorkflowRun[]
    },
    async jobs(runId) {
      const body = await get(`actions/runs/${runId}/jobs?filter=latest&per_page=100`)
      if (!Array.isArray(body.jobs)) throw new Error(`GitHub API returned no jobs for run ${runId}`)
      return body.jobs as WorkflowJob[]
    },
  }
}

const escapeCommand = (value: string) => value.replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A")

export function table(verdicts: Verdict[]): string {
  const icon = { green: "✅", deferred: "➡️", pending: "⏳", red: "❌" }
  return ["| Gated job | Result |", "| --- | --- |",
    ...verdicts.map((verdict) => `| ${verdict.name} | ${icon[verdict.state]} ${verdict.url ? `[${verdict.detail}](${verdict.url})` : verdict.detail} |`)].join("\n")
}

export async function main(env: Record<string, string | undefined>, args: string[], fetcher?: Fetcher,
  log: (line: string) => void = console.log, pause?: (ms: number) => Promise<void>): Promise<number> {
  const summary = (text: string) => { if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, `${text}\n\n`) }
  const sha = env.RELEASE_SHA ?? ""
  if (env.ROLLBACK === "true" || env.PUBLISH_ONLY === "true") {
    summary("#### Deploy gate: not applicable\n\nRollbacks and publication-only runs are not gated.")
    log("Deploy gate not applicable")
    return 0
  }
  const fetch = fetcher ?? githubFetcher(env.GITHUB_REPOSITORY ?? "", sha, env.GH_TOKEN ?? "")
  let result: Awaited<ReturnType<typeof evaluate>>
  try {
    result = await evaluate({ sha, fetch, wait: args.includes("--wait"), log, ...(pause ? { pause } : {}) })
  } catch (error) {
    const message = error instanceof Error ? error.message : "Deploy gate failed"
    summary(`#### Deploy gate: unavailable\n\n${message}`)
    log(`::error title=Deploy gate unavailable::${escapeCommand(message)}`)
    return 1
  }
  const status = result.ok ? "passed" : result.verdicts.some((verdict) => verdict.state === "red") ? "failed" : "timed out"
  const advice = status === "timed out"
    ? `Gated jobs were still running after ${WAIT_MINUTES} minutes; nothing in production changed. Dispatch again (or Re-run failed jobs) once they finish, or dispatch with \`skip_gate\` and a \`skip_reason\` (incidents).`
    : "Fix or rerun the failed job, then use Re-run failed jobs on this deploy run (nothing in production changed), or dispatch again with `skip_gate` and a `skip_reason` (incidents)."
  summary(`#### Deploy gate: ${status}\n\n${table(result.verdicts)}${result.ok ? "" : `\n\n${advice}`}`)
  for (const verdict of result.verdicts) log(`${verdict.name}: ${verdict.state} (${verdict.detail})`)
  if (!result.ok) log(`::error title=Deploy gate ${status}::${escapeCommand(result.verdicts.filter((verdict) => verdict.state === "red" || verdict.state === "pending")
    .map((verdict) => `${verdict.name} ${verdict.detail}`).join("; "))}. ${status === "timed out" ? `Still running after ${WAIT_MINUTES} minutes: dispatch again once it finishes` : "Re-run failed jobs once it is green"}, or dispatch with skip_gate and skip_reason.`)
  return result.ok ? 0 : 1
}

if (import.meta.main) process.exitCode = await main(process.env, process.argv.slice(2))
