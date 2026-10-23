#!/usr/bin/env node
// Run from trusted main before checking out, installing or executing the candidate.
import { execFileSync } from "node:child_process"
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
import { parseReleaseTag } from "./release-tag.mjs"

const REPOSITORY = "inline-chat/inline"
const SHA = /^[0-9a-f]{40}$/
export const REQUIRED_JOBS = {
  cli: ["Rust workspace all targets", "Workflow and release contracts"],
  npm: ["Shared TypeScript packages", "Workflow and release contracts", "Pack seven candidate npm packages", "Packed consumer (Node 20)", "Packed consumer (Node 26)"],
}

export class ReleaseGateError extends Error {
  constructor(message, outcome = "blocked") {
    super(message)
    this.outcome = outcome
  }
}

const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim()
const github = (resource) => JSON.parse(execFileSync("gh", ["api", `repos/${REPOSITORY}/${resource}`], {
  encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
}))

export function qualifyRelease({ tag, commit, surface, allowUntagged = false, repository = process.env.GITHUB_REPOSITORY,
  runGit = git, api = github }) {
  if (repository !== REPOSITORY || !REQUIRED_JOBS[surface]) throw new ReleaseGateError("Release requires the trusted Inline repository and surface")
  const release = tag ? parseReleaseTag(tag, surface) : undefined
  if (!release && !allowUntagged) throw new ReleaseGateError("Publishing requires an existing release tag")
  if (commit && (commit.length !== 40 || !SHA.test(commit))) throw new ReleaseGateError("Release commit must be a full lowercase SHA")
  let sha = commit
  if (release) {
    runGit("fetch", "--no-tags", "origin", `refs/tags/${release.tag}`)
    sha = runGit("rev-parse", "FETCH_HEAD^{commit}")
    if (!SHA.test(sha) || (commit && sha !== commit)) throw new ReleaseGateError("Release tag does not point to the expected commit")
  }
  if (!SHA.test(sha || "")) throw new ReleaseGateError("A full release commit is required")
  runGit("fetch", "--no-tags", "origin", "main")
  try { runGit("merge-base", "--is-ancestor", sha, "FETCH_HEAD") }
  catch { throw new ReleaseGateError("Release commit is not on main") }

  const runs = api(`actions/workflows/integrations.yml/runs?branch=main&event=push&head_sha=${sha}&per_page=100`).workflow_runs
    .filter((run) => run.head_sha === sha && run.head_branch === "main" && run.event === "push" &&
      run.head_repository?.full_name === REPOSITORY)
    .sort((a, b) => b.id - a.id)
  const run = runs[0]
  if (!run || run.status !== "completed") throw new ReleaseGateError("Main CI for this commit is not complete; rerun after it finishes", "deferred")
  const jobs = []
  for (let page = 1; page <= 10; page++) {
    const batch = api(`actions/runs/${run.id}/jobs?filter=latest&per_page=100&page=${page}`).jobs
    jobs.push(...batch)
    if (batch.length < 100) break
    if (page === 10) throw new ReleaseGateError("Too many CI jobs to qualify the release")
  }
  for (const name of REQUIRED_JOBS[surface]) {
    const matches = jobs.filter((job) => job.name === name)
    if (matches.length !== 1 || matches[0].status !== "completed" || matches[0].conclusion !== "success") {
      throw new ReleaseGateError(`Required ${surface} CI job has not passed: ${name}`)
    }
  }
  return { sha, tag: release?.tag || "", version: release?.version || "", channel: release?.channel || "",
    "package-key": release?.packageKey || "cli", "package-dir": release?.directory || "", "package-name": release?.name || "", outcome: "qualified" }
}

function output(values) {
  if (process.env.GITHUB_OUTPUT) {
    for (const [key, value] of Object.entries(values)) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${String(value).replace(/[\r\n]/g, " ")}\n`)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const result = qualifyRelease({ tag: process.env.RELEASE_TAG, commit: process.env.RELEASE_COMMIT,
      surface: process.env.RELEASE_SURFACE, allowUntagged: process.argv.includes("--allow-untagged") })
    output(result)
    console.log(`Qualified ${result.tag || "diagnostic candidate"} on main at ${result.sha}`)
  } catch (error) {
    const reason = error instanceof ReleaseGateError ? error.message : "Release qualification failed; verify tag, main ancestry and CI access"
    output({ outcome: error instanceof ReleaseGateError ? error.outcome : "blocked", reason })
    console.error(reason)
    process.exitCode = 1
  }
}
