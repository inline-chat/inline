#!/usr/bin/env node
// Cuts automated CLI alphas from the newest green CLI change on main, the way the
// Tip and Early Testers gates release Apple builds. Runs from trusted main and never
// executes candidate code: it tags the selected commit and dispatches CLI Release,
// which requalifies the tag and stamps the alpha version at build time.
import { execFileSync } from "node:child_process"
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
import { CLI_UPDATE_JOBS, REQUIRED_JOBS, ReleaseGateError, requireWorkflowJobs } from "./assert-release-commit.mjs"
import { compareVersions } from "./publish-npm-release.mjs"
import { canonicalSemver } from "./release-tag.mjs"

const REPOSITORY = "inline-chat/inline"
const SHA = /^[0-9a-f]{40}$/
const ALPHA = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-alpha\.(0|[1-9]\d*)$/
const STABLE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/
export const MIN_ALPHA_INTERVAL_MS = 3 * 60 * 60 * 1000
const MAIN_COMMIT_WINDOW = 50
const CI_WORKFLOW = "integrations.yml"
// Path-filtered to CLI inputs on main pushes, so its run marks a CLI change.
const CLI_CHANGE_WORKFLOW = "cli-update-qualification.yml"
const RELEASE_WORKFLOW = "cli-release.yml"
export const RELEASE = "release", CURRENT = "already-current", DEFERRED = "deferred", BLOCKED = "blocked"

export function github(resource, { method = "GET", body, missingOk = false } = {}) {
  const args = ["api", "--method", method, `repos/${REPOSITORY}/${resource}`]
  if (body) args.push("--input", "-")
  try {
    const output = execFileSync("gh", args, {
      encoding: "utf8", input: body ? JSON.stringify(body) : undefined, stdio: ["pipe", "pipe", "pipe"], maxBuffer: 256 * 1024 * 1024,
    })
    return output.trim() ? JSON.parse(output) : null
  } catch (error) {
    if (missingOk && /HTTP 404/.test(String(error.stderr))) return null
    throw error
  }
}

/** Next alpha above every CLI tag and the committed workspace version. */
export function nextAlphaVersion(tagVersions, committedVersion) {
  const base = [...tagVersions, committedVersion].filter(Boolean).sort(compareVersions).at(-1)
  if (!base) throw new ReleaseGateError("No CLI version to continue from")
  const alpha = ALPHA.exec(base)
  if (alpha) return `${alpha[1]}.${alpha[2]}.${alpha[3]}-alpha.${BigInt(alpha[4]) + 1n}`
  const stable = STABLE.exec(base)
  if (stable) return `${stable[1]}.${stable[2]}.${BigInt(stable[3]) + 1n}-alpha.1`
  throw new ReleaseGateError(`Newest CLI version ${base} is neither an alpha nor stable; continue it with release:cli`)
}

function cliTags(api) {
  const refs = api("git/matching-refs/tags/cli-v") ?? []
  const tags = []
  for (const ref of refs) {
    const tag = ref.ref.replace(/^refs\/tags\//, "")
    try { tags.push({ tag, version: canonicalSemver(tag.slice("cli-v".length)), object: ref.object }) } catch { /* not a release tag */ }
  }
  return tags.sort((a, b) => compareVersions(a.version, b.version))
}

/** Peel a tag ref to its commit, with the annotated tag's creation time when present. */
function peel(api, object) {
  let target = object, taggedAt = null
  for (let depth = 0; depth < 3; depth++) {
    if (target.type === "commit" && SHA.test(target.sha)) return { sha: target.sha, taggedAt }
    if (target.type !== "tag") break
    const tag = api(`git/tags/${target.sha}`)
    taggedAt ??= tag.tagger?.date ? Date.parse(tag.tagger.date) : null
    target = tag.object
  }
  throw new ReleaseGateError("A CLI tag did not resolve to a commit")
}

function latestMainPushRuns(api, workflow) {
  const runs = new Map()
  for (const run of api(`actions/workflows/${workflow}/runs?branch=main&event=push&per_page=100`).workflow_runs) {
    if (run.head_branch !== "main" || run.event !== "push" || run.head_repository?.full_name !== REPOSITORY) continue
    if (!runs.has(run.head_sha) || runs.get(run.head_sha).id < run.id) runs.set(run.head_sha, run)
  }
  return runs
}

export function committedVersion(api, sha) {
  const file = api(`contents/Cargo.toml?ref=${sha}`)
  const contents = Buffer.from(file.content, file.encoding === "base64" ? "base64" : "utf8").toString("utf8")
  const section = /^\[workspace\.package\]\s*$([\s\S]*?)(?=^\[|(?![\s\S]))/m.exec(contents)?.[1] ?? ""
  const version = /^version\s*=\s*"([^"]+)"/m.exec(section)?.[1]
  if (!version) throw new ReleaseGateError("Could not read the committed CLI workspace version")
  return canonicalSemver(version)
}

/** Return { sha, outcome, reason, tag, version } for the newest green CLI change on main. */
export function selectCliAlpha({ api = github, event = "workflow_dispatch", now = Date.now() } = {}) {
  if (api(`actions/workflows/${RELEASE_WORKFLOW}/runs?per_page=30`).workflow_runs.some((run) => run.status !== "completed")) {
    return { outcome: DEFERRED, reason: "a CLI release is already running" }
  }
  const tags = cliTags(api)
  const latest = tags.at(-1)
  const published = latest ? peel(api, latest.object) : null
  const ci = latestMainPushRuns(api, CI_WORKFLOW)
  const changes = latestMainPushRuns(api, CLI_CHANGE_WORKFLOW)

  let running = null, candidate = null
  for (const commit of api(`commits?sha=main&per_page=${MAIN_COMMIT_WINDOW}`)) {
    const sha = commit.sha
    if (!SHA.test(sha) || sha === published?.sha) break
    const change = changes.get(sha)
    if (!change) continue
    const build = ci.get(sha)
    if (change.status !== "completed" || build?.status !== "completed") { running ??= sha; continue }
    try {
      requireWorkflowJobs(sha, CI_WORKFLOW, REQUIRED_JOBS.cli, "cli", "Main CI", api)
      requireWorkflowJobs(sha, CLI_CHANGE_WORKFLOW, CLI_UPDATE_JOBS, "CLI update", "CLI update qualification", api)
      candidate = sha
      break
    } catch (error) {
      if (!(error instanceof ReleaseGateError)) throw error
      console.log(`Not green: ${sha.slice(0, 9)} (${error.message})`)
    }
  }

  // Each CI completion retriggers the gate, so wait for a newer change instead of
  // publishing one that is about to be superseded. The sweep never waits.
  if (running && event === "workflow_run") return { sha: running, outcome: DEFERRED, reason: `newer CLI change ${running.slice(0, 9)} is still in CI` }
  if (!candidate) {
    return running
      ? { sha: running, outcome: DEFERRED, reason: `CLI change ${running.slice(0, 9)} is still in CI` }
      : { sha: published?.sha, outcome: CURRENT, reason: `no green CLI change on main since ${latest?.tag ?? "the last release"}` }
  }
  if (published && api(`compare/${published.sha}...${candidate}`).status !== "ahead") {
    return { sha: candidate, outcome: CURRENT, reason: `${latest.tag} already includes this commit` }
  }
  if (event !== "workflow_dispatch" && published?.taggedAt && now - published.taggedAt < MIN_ALPHA_INTERVAL_MS) {
    return { sha: candidate, outcome: DEFERRED, reason: `${latest.tag} was tagged at ${new Date(published.taggedAt).toISOString()}, under 3 hours ago` }
  }
  const version = nextAlphaVersion(tags.map((entry) => entry.version), committedVersion(api, candidate))
  return { sha: candidate, outcome: RELEASE, reason: "newest green CLI change on main", tag: `cli-v${version}`, version }
}

/** Create the immutable alpha tag on the selected commit and start CLI Release for it. */
export function publishCliAlpha({ api = github, sha, tag, version }) {
  if (!SHA.test(sha || "") || !ALPHA.test(version || "") || tag !== `cli-v${version}`) {
    throw new ReleaseGateError("Publishing needs the selected commit and its alpha tag")
  }
  const existing = api(`git/ref/tags/${tag}`, { missingOk: true })
  if (existing) {
    if (peel(api, existing.object).sha !== sha) throw new ReleaseGateError(`${tag} already exists on another commit`)
  } else {
    const object = api("git/tags", { method: "POST", body: { tag, message: `CLI ${version} (automated alpha)`, object: sha, type: "commit" } })
    try {
      api("git/refs", { method: "POST", body: { ref: `refs/tags/${tag}`, sha: object.sha } })
    } catch (error) {
      // The tag was absent a moment ago, so a refusal here is the creation ruleset.
      if (/HTTP 40[13]|HTTP 422|rule/i.test(String(error?.stderr ?? error?.message))) {
        throw new ReleaseGateError(`GitHub Actions could not create ${tag}; add it to the bypass list of the "Release tags: admin creation" ruleset`)
      }
      throw error
    }
  }
  api(`actions/workflows/${RELEASE_WORKFLOW}/dispatches`, { method: "POST", body: { ref: "main", inputs: { tag } } })
}

function output(values) {
  if (!process.env.GITHUB_OUTPUT) return
  for (const [key, value] of Object.entries(values)) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${String(value ?? "").replace(/[\r\n]/g, " ")}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const mode = process.argv[2]
  try {
    if (mode === "select") {
      const event = process.env.GITHUB_EVENT_NAME || "workflow_dispatch"
      const result = selectCliAlpha({ event })
      console.log(`CLI alpha (${event}): ${result.outcome}: ${result.reason}${result.sha ? ` (${result.sha})` : ""}`)
      output({ sha: result.sha, tag: result.tag, version: result.version, outcome: result.outcome,
        reason: result.reason, should_release: result.outcome === RELEASE })
    } else if (mode === "publish") {
      publishCliAlpha({ sha: process.env.SHA, tag: process.env.TAG, version: process.env.VERSION })
      console.log(`Tagged ${process.env.TAG} at ${process.env.SHA} and started CLI Release`)
    } else {
      throw new Error("Usage: cli-alpha-gate.mjs <select|publish>")
    }
  } catch (error) {
    const blocked = error instanceof ReleaseGateError
    output({ outcome: blocked ? error.outcome : "failed", reason: blocked ? error.message : "CLI alpha gate failed; inspect the log", should_release: false })
    console.error(error instanceof Error ? error.message : error)
    process.exitCode = 1
  }
}
