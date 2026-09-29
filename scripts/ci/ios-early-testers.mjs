#!/usr/bin/env node
// The only distribution mutation allowed here is adding the internal Early Testers group.
import { createPrivateKey, sign } from "node:crypto"
import { execFileSync } from "node:child_process"
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"

export const APP = "6736995294"
export const GROUP = "6b986a51-e0b9-437f-b0e5-208b05caee18"
export const WORKFLOW = "a39d4e34-0912-4454-a728-ac1549929c9c"
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

export async function publish({ api, sha, qualify, pause = sleep, now = Date.now, log = console.log }) {
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
    const refs = await list(api, `/v1/scmRepositories/${REPOSITORY}/gitReferences?limit=200`)
    const main = refs.find((ref) => ref.attributes.canonicalName === "refs/heads/main" && !ref.attributes.isDeleted)
    if (!main) throw new Error("Xcode Cloud main reference is missing")
    // Apple selects a branch rather than accepting a SHA. Check its resolved source before distributing.
    run = (await api("/v1/ciBuildRuns", { data: { type: "ciBuildRuns", relationships: {
      workflow: { data: { type: "ciWorkflows", id: WORKFLOW } },
      sourceBranchOrTag: { data: { type: "scmGitReferences", id: main.id } },
    } } })).data
    log(`Started Xcode Cloud run ${run.id} for ${sha}`)
  } else log(`Resuming Xcode Cloud run ${run.id} for ${sha}`)
  while (true) {
    run = (await api(`/v1/ciBuildRuns/${run.id}`)).data
    if (run.attributes.sourceCommit) validateRun(run, sha)
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
  const groupsPath = `/v1/betaGroups?filter[app]=${APP}&filter[builds]=${build.id}&limit=200`
  const groups = await list(api, groupsPath)
  if (groups.some((item) => item.attributes.isInternalGroup !== true)) {
    throw new Error("Build already has external distribution; refusing automatic promotion")
  }
  const testers = await list(api, `/v1/builds/${build.id}/individualTesters?limit=200`)
  if (testers.length) throw new Error("Build has individual tester assignments; manual review required")
  await qualify()
  if (!groups.some((item) => item.id === GROUP)) {
    await api(`/v1/betaGroups/${GROUP}/relationships/builds`, { data: [{ type: "builds", id: build.id }] })
  }
  const final = await list(api, groupsPath)
  if (!final.some((item) => item.id === GROUP) || final.some((item) => !item.attributes.isInternalGroup)) {
    throw new Error("Internal distribution readback failed")
  }
  log(`Verified iOS ${version.attributes.version} (${build.attributes.version}) for internal Early Testers: ${sha}`)
  return { sha, run: run.id, build: build.id, version: build.attributes.version }
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
    })
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `Internal Early Testers: build **${result.version}**, source \`${result.sha}\`, Xcode Cloud run \`${result.run}\`.\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : "iOS early tester release failed")
    process.exitCode = 1
  }
}
