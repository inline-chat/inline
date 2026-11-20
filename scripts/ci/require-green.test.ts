import { describe, expect, it } from "bun:test"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { GATES, WAIT_MINUTES, evaluate, githubFetcher, judgeJob, main, type Fetcher, type WorkflowJob, type WorkflowRun } from "./require-green"

const sha = "a".repeat(40)
const run = (id: number, status = "completed", head = sha): WorkflowRun =>
  ({ id, head_sha: head, status, conclusion: status === "completed" ? "failure" : null, html_url: `https://github.com/inline-chat/inline/actions/runs/${id}` })
const job = (name: string, status: string, conclusion: string | null = null): WorkflowJob => ({ name, status, conclusion })
const [server, ci] = GATES as [typeof GATES[0], typeof GATES[0]]
const serverJob = server.jobs[0]!
const ciJob = ci.jobs[0]!

// Every gated job in one state; `overrides` changes single jobs.
function fake(state: [string, string | null], overrides: Record<string, [string, string | null]> = {}, runStatus = "completed"): Fetcher {
  return {
    runs: async (file) => [run(file === "integrations.yml" ? 1 : 2, runStatus)],
    jobs: async (id) => (id === 1 ? ci : server).jobs.map((name) => job(name, ...(overrides[name] ?? state)))
      .concat(id === 1 ? [job("Workflow and release contracts", "completed", "failure"), job("Rust workspace all targets", "completed", "failure")] : []),
  }
}

describe("deploy gate verdicts", () => {
  it("gates on exactly the server-relevant jobs", () => {
    expect(GATES.map((gate) => [gate.file, gate.jobs])).toEqual([
      ["server-test.yml", ["Server Typecheck, Lint, and Tests", "Server Linux image and migration commands", "Server ARM64 Coolify image and runtime"]],
      ["integrations.yml", ["Shared TypeScript packages", "Packed adapters with local Inline server"]],
    ])
  })

  it("ignores unrelated red CI jobs", async () => {
    const result = await evaluate({ sha, fetch: fake(["completed", "success"]) })
    expect(result.ok).toBe(true)
    expect(result.verdicts.every((verdict) => verdict.state === "green")).toBe(true)
  })

  it("fails a gated CI job on failure or a skipped dependency, waits while it runs, and flags a renamed job", () => {
    const at = (jobs: WorkflowJob[], status = "completed") => judgeJob(ci, ciJob, [{ run: run(1, status), jobs }])
    for (const conclusion of ["failure", "timed_out", "startup_failure"]) expect(at([job(ciJob, "completed", conclusion)]).state).toBe("red")
    expect(at([job(ciJob, "completed", "skipped")]).detail).toContain("dependency failed")
    expect(at([job(ciJob, "in_progress")], "in_progress").state).toBe("pending")
    expect(at([], "queued").state).toBe("pending")
    expect(at([job(ciJob, "completed", "cancelled")]).state).toBe("pending")
    expect(at([]).detail).toContain("update GATES")
    expect(judgeJob(ci, ciJob, []).state).toBe("pending")
    // Any successful attempt of the same commit is enough.
    expect(judgeJob(ci, ciJob, [{ run: run(3), jobs: [job(ciJob, "completed", "failure")] }, { run: run(2), jobs: [job(ciJob, "completed", "success")] }]).state).toBe("green")
  })

  it("defers cancelled, missing or running Server Tests to qualification but fails a failed job", () => {
    for (const jobs of [[job(serverJob, "completed", "cancelled")], [job(serverJob, "in_progress")], []]) {
      expect(judgeJob(server, serverJob, [{ run: run(1), jobs }]).state).toBe("deferred")
    }
    expect(judgeJob(server, serverJob, []).state).toBe("deferred")
    expect(judgeJob(server, serverJob, [{ run: run(1), jobs: [job(serverJob, "completed", "failure")] }]).state).toBe("red")
  })

  it("waits for a running gated job, fails fast on red, and times out", async () => {
    let calls = 0
    const sequence: Fetcher = { ...fake(["completed", "success"]),
      jobs: async (id) => id === 1 && calls++ === 0 ? ci.jobs.map((name) => job(name, "in_progress")) : fake(["completed", "success"]).jobs(id) }
    const pauses: number[] = []
    expect((await evaluate({ sha, wait: true, fetch: sequence, pause: async (ms) => { pauses.push(ms) } })).ok).toBe(true)
    expect(pauses).toEqual([30_000])
    const red = await evaluate({ sha, wait: true, pause: async () => { throw new Error("must not wait") },
      fetch: fake(["in_progress", null], { [serverJob]: ["completed", "failure"] }, "in_progress") })
    expect(red.ok).toBe(false)
    let clock = 0
    const timedOut = await evaluate({ sha, wait: true, deadlineMs: 60_000, now: () => clock, pause: async (ms) => { clock += ms },
      fetch: fake(["in_progress", null], {}, "in_progress") })
    expect(timedOut.ok).toBe(false)
    expect(clock).toBe(60_000)
    // The default cap stays near qualify's duration: the run holds the production lock meanwhile.
    clock = 0
    expect(WAIT_MINUTES).toBe(15)
    expect((await evaluate({ sha, wait: true, now: () => clock, pause: async (ms) => { clock += ms },
      fetch: fake(["in_progress", null], {}, "in_progress") })).ok).toBe(false)
    expect(clock).toBe(15 * 60_000)
    await expect(evaluate({ sha: "abc", fetch: fake(["completed", "success"]) })).rejects.toThrow("full commit")
  })

  it("reads push runs of the exact commit and their latest jobs with the token as a header", async () => {
    const seen: Array<{ url: string; init?: RequestInit }> = []
    const fetcher = githubFetcher("inline-chat/inline", sha, "gh-token", (async (url: string, init?: RequestInit) => {
      seen.push({ url, init })
      return new Response(JSON.stringify(url.includes("/jobs") ? { jobs: [] } : { workflow_runs: [run(1)] }))
    }) as typeof fetch)
    expect(await fetcher.runs("integrations.yml")).toHaveLength(1)
    expect(await fetcher.jobs(7)).toEqual([])
    expect(seen.map((entry) => entry.url)).toEqual([
      `https://api.github.com/repos/inline-chat/inline/actions/workflows/integrations.yml/runs?head_sha=${sha}&event=push&per_page=20`,
      "https://api.github.com/repos/inline-chat/inline/actions/runs/7/jobs?filter=latest&per_page=100",
    ])
    expect((seen[0]!.init!.headers as Record<string, string>).Authorization).toBe("Bearer gh-token")
    const failing = githubFetcher("inline-chat/inline", sha, "t", (async () => new Response("", { status: 502 })) as unknown as typeof fetch)
    await expect(failing.runs("integrations.yml")).rejects.toThrow("skip_gate")
    expect(() => githubFetcher("inline-chat/inline?x", sha, "t")).toThrow("GITHUB_REPOSITORY")
  })
})

describe("deploy gate entry point", () => {
  const scratch = () => {
    const directory = mkdtempSync(path.join(tmpdir(), "inline-gate-"))
    const file = path.join(directory, "summary.md")
    return { file, read: () => { try { return readFileSync(file, "utf8") } catch { return "" } }, cleanup: () => rmSync(directory, { recursive: true, force: true }) }
  }
  const unused: Fetcher = { runs: async () => { throw new Error("must not query GitHub") }, jobs: async () => [] }

  it("does not apply to rollbacks or publication-only runs", async () => {
    for (const env of [{ ROLLBACK: "true" }, { PUBLISH_ONLY: "true" }]) {
      const s = scratch()
      try {
        expect(await main({ RELEASE_SHA: sha, GITHUB_STEP_SUMMARY: s.file, ...env }, [], unused, () => {})).toBe(0)
        expect(s.read()).toContain("not applicable")
      } finally { s.cleanup() }
    }
  })

  it("reports each gated job, and tells a failed gate to rerun this deploy", async () => {
    const s = scratch()
    try {
      expect(await main({ RELEASE_SHA: sha, GITHUB_STEP_SUMMARY: s.file }, [], fake(["completed", "success"]), () => {})).toBe(0)
      expect(s.read()).toContain("Deploy gate: passed")
      expect(s.read()).toContain("| CI: Packed adapters with local Inline server | ✅")
      const lines: string[] = []
      expect(await main({ RELEASE_SHA: sha, GITHUB_STEP_SUMMARY: s.file }, ["--wait"],
        fake(["completed", "success"], { [ciJob]: ["completed", "failure"] }), (line) => lines.push(line))).toBe(1)
      expect(s.read()).toContain("Deploy gate: failed")
      expect(s.read()).toContain("Re-run failed jobs on this deploy run")
      expect(lines.at(-1)).toStartWith("::error title=Deploy gate failed::CI: Shared TypeScript packages failure in run 1")
      const waited: string[] = []
      let clock = 0
      const realNow = Date.now
      Date.now = () => clock
      try {
        expect(await main({ RELEASE_SHA: sha, GITHUB_STEP_SUMMARY: s.file }, ["--wait"], fake(["in_progress", null], {}, "in_progress"),
          (line) => waited.push(line), async (ms) => { clock += ms })).toBe(1)
      } finally { Date.now = realNow }
      expect(s.read()).toContain("Deploy gate: timed out")
      expect(s.read()).toContain("still running after 15 minutes")
      expect(waited.at(-1)).toContain("dispatch again once it finishes, or dispatch with skip_gate")
      expect(await main({ RELEASE_SHA: sha, GITHUB_STEP_SUMMARY: s.file }, [], { ...unused, runs: async () => { throw new Error("GitHub API returned HTTP 502") } }, () => {})).toBe(1)
      expect(s.read()).toContain("Deploy gate: unavailable")
    } finally { s.cleanup() }
  })
})
