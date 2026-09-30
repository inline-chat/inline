#!/usr/bin/env node
// The only distribution mutation allowed here is adding the internal Early Testers group.
import { createPrivateKey, sign } from "node:crypto"
import { execFileSync } from "node:child_process"
import { appendFileSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

export const APP = "6736995294"
export const GROUP = "6b986a51-e0b9-437f-b0e5-208b05caee18"
export const WORKFLOW = "4f8a5391-2131-4b3f-9306-49d04390d5c8"
const REPOSITORY = "e8a64afc-f77d-488f-b7fb-1aadbe4a092f"
const ROOT = "https://api.appstoreconnect.apple.com"
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

export function makeToken(env, now = Math.floor(Date.now() / 1000)) {
  if (!env.ASC_KEY_ID || !env.ASC_ISSUER_ID || !env.ASC_PRIVATE_KEY) {
    throw new Error("App Store Connect team key is required")
  }
  const key = createPrivateKey(env.ASC_PRIVATE_KEY)
  if (key.asymmetricKeyDetails?.namedCurve !== "prime256v1") throw new Error("Expected a P-256 team key")
  const encode = (data) => Buffer.from(JSON.stringify(data)).toString("base64url")
  const body = `${encode({ alg: "ES256", kid: env.ASC_KEY_ID, typ: "JWT" })}.${encode({
    iss: env.ASC_ISSUER_ID, iat: now, exp: now + 600, aud: "appstoreconnect-v1",
  })}`
  return `${body}.${sign("sha256", Buffer.from(body), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`
}

export function appleClient(env, fetcher = fetch) {
  return async (path, data) => {
    const url = new URL(path, ROOT)
    if (url.origin !== ROOT || !url.pathname.startsWith("/v1/")) throw new Error("Unexpected Apple API URL")
    // Do not log JWTs, private keys, request headers, or provider error bodies.
    const response = await fetcher(url, {
      method: data ? "POST" : "GET", redirect: "error", signal: AbortSignal.timeout(60_000),
      headers: { Authorization: `Bearer ${makeToken(env)}`, "Content-Type": "application/json" },
      ...(data ? { body: JSON.stringify(data) } : {}),
    })
    if (!response.ok) throw new Error(`Apple API ${response.status}: ${url.pathname}`)
    return response.status === 204 ? {} : response.json()
  }
}

export async function list(api, path) {
  const items = []
  for (let page = 0; path && page < 20; page++) {
    const result = await api(path)
    items.push(...result.data)
    path = result.links?.next
  }
  if (path) throw new Error("Apple pagination limit exceeded")
  return items
}

export async function buildGroups(api, buildId) {
  const groups = await list(api, `/v1/apps/${APP}/betaGroups?limit=200`)
  const members = []
  for (const group of groups) {
    // Apple's documented filter[builds] is rejected for some builds.
    const builds = await list(api, `/v1/betaGroups/${group.id}/relationships/builds?limit=200`)
    if (builds.some((build) => build.id === buildId)) members.push(group)
  }
  return members
}

export function publicationReceipt(env = process.env, fetcher = fetch) {
  if (env.GITHUB_REPOSITORY !== "inline-chat/inline" || !env.GH_TOKEN) throw new Error("Trusted GitHub release token required")
  const root = "https://api.github.com/repos/inline-chat/inline"
  const request = async (path, data) => {
    const response = await fetcher(`${root}/${path}`, {
      method: data ? "POST" : "GET", redirect: "error", signal: AbortSignal.timeout(30_000),
      headers: { Authorization: `Bearer ${env.GH_TOKEN}`, Accept: "application/vnd.github+json", "Content-Type": "application/json" },
      ...(data ? { body: JSON.stringify(data) } : {}),
    })
    if (!response.ok) throw new Error(`GitHub release receipt failed: ${response.status}`)
    return response.json()
  }
  const context = "ios/early-testers"
  const description = (build) => `Early Testers build ${build}`
  return {
    isPublished: async (sha, build) => {
      const result = await request(`commits/${sha}/status`)
      return result.statuses.some((status) => status.context === context && status.state === "success"
        && status.description === description(build) && status.creator?.login === "github-actions[bot]")
    },
    markPublished: async (result) => request(`statuses/${result.sha}`, {
      state: "success", context, description: description(result.build),
      target_url: `https://github.com/inline-chat/inline/actions/runs/${env.GITHUB_RUN_ID}`,
    }),
  }
}

export function validateGroup(group, app) {
  if (group.id !== GROUP || group.attributes?.isInternalGroup !== true || app.id !== APP) {
    throw new Error("Refusing distribution outside Inline internal Early Testers")
  }
}

export function validateRun(run, sha) {
  if (run.attributes?.sourceCommit?.commitSha !== sha || run.attributes?.isPullRequestBuild === true) {
    throw new Error("Xcode Cloud source differs from the qualified main commit")
  }
}

export function validateBuild(build, app, version) {
  if (app.id !== APP || version.attributes?.platform !== "IOS" || build.attributes?.expired
      || build.attributes?.processingState !== "VALID"
      || build.attributes?.buildAudienceType !== "APP_STORE_ELIGIBLE") {
    throw new Error("Expected a valid, unexpired Inline iOS archive")
  }
}

export function reusableRun(runs, sha) {
  return runs.find((run) => run.attributes?.sourceCommit?.commitSha === sha
    && (run.attributes.executionProgress !== "COMPLETE" || run.attributes.completionStatus === "SUCCEEDED"))
}

export async function ensureSourceTag(sha, env = process.env, fetcher = fetch) {
  if (env.GITHUB_REPOSITORY !== "inline-chat/inline" || !env.GH_TOKEN || !/^[0-9a-f]{40}$/.test(sha)) {
    throw new Error("Source tags require the trusted Inline repository and qualified SHA")
  }
  const tag = `ios-early-testers/${sha}`
  const root = "https://api.github.com/repos/inline-chat/inline"
  const request = (path, data) => fetcher(`${root}/${path}`, {
    method: data ? "POST" : "GET", redirect: "error", signal: AbortSignal.timeout(30_000),
    headers: { Authorization: `Bearer ${env.GH_TOKEN}`, Accept: "application/vnd.github+json", "Content-Type": "application/json" },
    ...(data ? { body: JSON.stringify(data) } : {}),
  })
  const response = await request(`git/ref/tags/${tag}`)
  if (response.status === 404) {
    const created = await request("git/refs", { ref: `refs/tags/${tag}`, sha })
    if (!created.ok) throw new Error(`GitHub source tag creation failed: ${created.status}`)
    const ref = await created.json()
    if (ref.object?.sha !== sha || ref.object?.type !== "commit") throw new Error("Created source tag differs from qualified SHA")
  } else {
    if (!response.ok) throw new Error(`GitHub source tag lookup failed: ${response.status}`)
    const ref = await response.json()
    if (ref.object?.sha !== sha || ref.object?.type !== "commit") throw new Error("Existing source tag differs from qualified SHA")
  }
  return `refs/tags/${tag}`
}

export async function preflight(api) {
  const group = (await api(`/v1/betaGroups/${GROUP}`)).data
  const groupApp = (await api(`/v1/betaGroups/${GROUP}/app`)).data
  validateGroup(group, groupApp)
  const workflow = (await api(`/v1/ciWorkflows/${WORKFLOW}`)).data
  if (!workflow.attributes.isEnabled || workflow.attributes.actions.length !== 1
      || workflow.attributes.actions[0].platform !== "IOS"
      || workflow.attributes.actions[0].buildDistributionAudience !== "APP_STORE_ELIGIBLE") {
    throw new Error("Expected the enabled, manual iOS archive workflow")
  }
  const repo = (await api(`/v1/ciWorkflows/${WORKFLOW}/repository`)).data
  if (repo.id !== REPOSITORY) throw new Error("Unexpected Xcode Cloud repository")
}

async function uploadSymbols(api, runId) {
  if (!process.env.SENTRY_AUTH_TOKEN) throw new Error("SENTRY_AUTH_TOKEN is required for release symbols")
  const actions = await list(api, `/v1/ciBuildRuns/${runId}/actions?limit=200`)
  const artifacts = []
  for (const action of actions) artifacts.push(...await list(api, `/v1/ciBuildActions/${action.id}/artifacts?limit=200`))
  const archives = artifacts.filter((item) => item.attributes.fileType === "ARCHIVE")
  if (archives.length !== 1) throw new Error("Expected one exact-run archive for Sentry symbols")
  const url = new URL(archives[0].attributes.downloadUrl)
  if (url.protocol !== "https:" || !url.hostname.endsWith(".icloud-content.com")) throw new Error("Unexpected Apple archive download host")
  // The signed artifact URL receives no Apple or GitHub bearer token.
  const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(300_000) })
  if (!response.ok) throw new Error(`Apple archive download failed: ${response.status}`)
  const archive = join(mkdtempSync(join(tmpdir(), "inline-ios-symbols-")), "archive.zip")
  writeFileSync(archive, Buffer.from(await response.arrayBuffer()))
  execFileSync("npx", ["--yes", "--package", "@sentry/cli@3.8.0", "sentry-cli", "debug-files", "upload", "--wait", archive], {
    stdio: "inherit", timeout: 600_000,
    env: { PATH: process.env.PATH, HOME: process.env.HOME, SENTRY_AUTH_TOKEN: process.env.SENTRY_AUTH_TOKEN,
      SENTRY_ORG: "usenoor", SENTRY_PROJECT: "inline-ios-macos", SENTRY_URL: "https://us.sentry.io" },
  })
}

export async function publish({ api, sha, qualify, sourceTag = ensureSourceTag, symbols = async () => {}, isPublished = async () => false, markPublished = async () => {}, pause = sleep, now = Date.now, log = console.log }) {
  if (!/^[0-9a-f]{40}$/.test(sha || "")) throw new Error("Expected a full qualified main SHA")
  const deadline = now() + 75 * 60_000
  const wait = async () => {
    if (now() >= deadline) throw new Error("Timed out; the next run will resume this Xcode Cloud build")
    await pause(30_000)
  }
  const group = (await api(`/v1/betaGroups/${GROUP}`)).data
  const groupApp = (await api(`/v1/betaGroups/${GROUP}/app`)).data
  validateGroup(group, groupApp)
  await qualify()
  const runs = await list(api, `/v1/ciWorkflows/${WORKFLOW}/buildRuns?sort=-number&limit=100`)
  let run = reusableRun(runs, sha)
  if (!run) {
    const canonicalName = await sourceTag(sha)
    let source
    while (!source) {
      const refs = await list(api, `/v1/scmRepositories/${REPOSITORY}/gitReferences?limit=200`)
      source = refs.find((ref) => ref.attributes.canonicalName === canonicalName && !ref.attributes.isDeleted)
      if (!source) await wait()
    }
    await qualify()
    // Pin an immutable tag: main may advance before Apple clones the source.
    run = (await api("/v1/ciBuildRuns", { data: { type: "ciBuildRuns", relationships: {
      workflow: { data: { type: "ciWorkflows", id: WORKFLOW } },
      sourceBranchOrTag: { data: { type: "scmGitReferences", id: source.id } },
    } } })).data
    log(`Started Xcode Cloud run ${run.id} for ${sha}`)
  } else log(`Resuming Xcode Cloud run ${run.id} for ${sha}`)
  while (true) {
    run = (await api(`/v1/ciBuildRuns/${run.id}`)).data
    // Apple may return an empty sourceCommit while a new run is pending.
    // Reject a resolved mismatch immediately; require an exact SHA at completion.
    if (run.attributes.sourceCommit?.commitSha) validateRun(run, sha)
    if (run.attributes.executionProgress === "COMPLETE") break
    await wait()
  }
  validateRun(run, sha)
  if (run.attributes.completionStatus !== "SUCCEEDED") throw new Error("Xcode Cloud archive failed")
  let builds
  while (true) {
    builds = await list(api, `/v1/ciBuildRuns/${run.id}/builds?limit=200`)
    if (builds.length) break
    await wait()
  }
  if (builds.length !== 1) throw new Error("Expected exactly one iOS archive for the run")
  let build
  while (true) {
    build = (await api(`/v1/builds/${builds[0].id}`)).data
    if (build.attributes.processingState !== "PROCESSING") break
    await wait()
  }
  const app = (await api(`/v1/builds/${build.id}/app`)).data
  const version = (await api(`/v1/builds/${build.id}/preReleaseVersion`)).data
  validateBuild(build, app, version)
  const result = { sha, run: run.id, build: build.id, version: build.attributes.version }
  const groups = await buildGroups(api, build.id)
  if (groups.some((item) => item.id === GROUP) && await isPublished(sha, build.id)) {
    log(`Already available to internal Early Testers: ${sha}, build ${build.attributes.version}`)
    return result
  }
  if (groups.some((item) => item.attributes.isInternalGroup !== true)) {
    throw new Error("Build already has external distribution; refusing automatic promotion")
  }
  const testers = await list(api, `/v1/builds/${build.id}/individualTesters?limit=200`)
  if (testers.length) throw new Error("Build has individual tester assignments; manual review required")
  await symbols(api, run.id)
  await qualify()
  if (!groups.some((item) => item.id === GROUP)) {
    await api(`/v1/betaGroups/${GROUP}/relationships/builds`, { data: [{ type: "builds", id: build.id }] })
  }
  const final = await buildGroups(api, build.id)
  if (!final.some((item) => item.id === GROUP) || final.some((item) => !item.attributes.isInternalGroup)) {
    throw new Error("Internal distribution readback failed")
  }
  await markPublished(result)
  log(`Verified iOS ${version.attributes.version} (${build.attributes.version}) for internal Early Testers: ${sha}`)
  return result
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.includes("--preflight")) {
      await preflight(appleClient(process.env))
      console.log("Verified Apple credentials, Inline iOS workflow and internal Early Testers group (read only)")
      process.exit(0)
    }
    const result = await publish({ api: appleClient(process.env), sha: process.env.EXPECTED_SHA,
      qualify: () => execFileSync("python3", ["scripts/ci/nightly-tip-gate.py", "qualify"], { stdio: "inherit" }),
      symbols: uploadSymbols,
      ...publicationReceipt(),
    })
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `Internal Early Testers: build **${result.version}**, source \`${result.sha}\`, Xcode Cloud run \`${result.run}\`.\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : "iOS early tester release failed")
    process.exitCode = 1
  }
}
