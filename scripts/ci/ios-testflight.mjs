#!/usr/bin/env node
// Promotes an existing qualified Early Testers build; never creates an archive.
import { execFileSync } from "node:child_process"
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
import { APP, GROUP, WORKFLOW, appleClient, buildGroups, list, validateBuild, validateRun } from "./ios-early-testers.mjs"

// Existing external TestFlight audience. Renaming it does not change its identity.
export const EXTERNAL_GROUP = "10b67ad7-a761-4ff7-b57e-461472ae08e6"

/** @param {(url: string, options: RequestInit) => Promise<Response>} fetcher */
export function internalPublication(env = process.env, fetcher = fetch) {
  if (env.GITHUB_REPOSITORY !== "inline-chat/inline" || !env.GH_TOKEN) throw new Error("Trusted GitHub release token required")
  const request = async (path) => {
    const response = await fetcher(`https://api.github.com/repos/inline-chat/inline/${path}`, {
      redirect: "error", signal: AbortSignal.timeout(30_000),
      headers: { Authorization: `Bearer ${env.GH_TOKEN}`, Accept: "application/vnd.github+json" },
    })
    if (!response.ok) throw new Error(`GitHub internal publication lookup failed: ${response.status}`)
    return response.json()
  }
  return async (sha, build) => {
    const statuses = await request(`commits/${sha}/statuses?per_page=100`)
    const receipt = statuses.find((item) => item.context === "ios/early-testers")
    if (receipt?.state !== "success" || receipt.description !== `Early Testers build ${build}`
        || receipt.creator?.login !== "github-actions[bot]") return false
    const runID = /^https:\/\/github\.com\/inline-chat\/inline\/actions\/runs\/(\d+)$/.exec(receipt.target_url || "")?.[1]
    if (!runID) return false
    const run = await request(`actions/runs/${runID}`)
    return run.status === "completed" && run.conclusion === "success" && run.head_branch === "main"
      && run.path === ".github/workflows/ios-early-testers.yml"
  }
}

export async function selectInternalBuild({ api, isPublished, now = Date.now() }) {
  const runs = await list(api, `/v1/ciWorkflows/${WORKFLOW}/buildRuns?sort=-number&limit=100`)
  for (const run of runs) {
    const sha = run.attributes?.sourceCommit?.commitSha
    if (run.attributes?.executionProgress !== "COMPLETE" || run.attributes.completionStatus !== "SUCCEEDED"
        || run.attributes.isPullRequestBuild === true || !/^[a-f0-9]{40}$/.test(sha || "")) continue
    const builds = await list(api, `/v1/ciBuildRuns/${run.id}/builds?limit=200`)
    if (builds.length !== 1 || !await isPublished(sha, builds[0].id)) continue
    const build = (await api(`/v1/builds/${builds[0].id}`)).data
    const expiration = Date.parse(build.attributes?.expirationDate)
    if (build.attributes?.expired !== false || build.attributes?.processingState !== "VALID"
        || !Number.isFinite(expiration) || expiration <= now) continue
    const app = (await api(`/v1/builds/${build.id}/app`)).data
    const version = (await api(`/v1/builds/${build.id}/preReleaseVersion`)).data
    validateBuild(build, app, version)
    const currentRun = (await api(`/v1/ciBuildRuns/${run.id}`)).data
    validateRun(currentRun, sha)
    if (currentRun.attributes.executionProgress !== "COMPLETE" || currentRun.attributes.completionStatus !== "SUCCEEDED") {
      throw new Error("Selected internal archive is no longer successful")
    }
    const groups = await buildGroups(api, build.id)
    if (!groups.some((group) => group.id === GROUP && group.attributes?.isInternalGroup === true)) continue
    return { sha, run: run.id, build: build.id, version: build.attributes.version, groups }
  }
  throw new Error("No valid, unexpired build has a successful qualified Early Testers publication")
}

export async function promoteTestFlight({ api, isPublished, qualify, now = Date.now() }) {
  const group = (await api(`/v1/betaGroups/${EXTERNAL_GROUP}`)).data
  const groupApp = (await api(`/v1/betaGroups/${EXTERNAL_GROUP}/app`)).data
  if (group.id !== EXTERNAL_GROUP || group.attributes?.isInternalGroup !== false || groupApp.id !== APP) {
    throw new Error("Expected Inline's existing external Early Users group")
  }
  const selected = await selectInternalBuild({ api, isPublished, now })
  await qualify(selected.sha)
  if (selected.groups.some((item) => item.attributes?.isInternalGroup === false && item.id !== EXTERNAL_GROUP)) {
    throw new Error("Selected build has another external audience")
  }
  if ((await list(api, `/v1/builds/${selected.build}/individualTesters?limit=200`)).length) {
    throw new Error("Selected build has individual tester assignments")
  }
  const detail = () => api(`/v1/builds/${selected.build}/buildBetaDetail`).then((response) => response.data)
  const before = (await detail()).attributes
  const reviews = await list(api, `/v1/betaAppReviewSubmissions?filter[build]=${selected.build}&limit=200`)
  const review = reviews[0]?.attributes?.betaReviewState
  const state = before.externalBuildState
  const blocked = ["BETA_REJECTED", "EXPIRED", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE", "NOT_APPLICABLE"]
  if (blocked.includes(state) || review === "REJECTED") {
    return { ...selected, outcome: "blocked", reason: `Apple requires action: ${state} (beta review ${review || "none"})` }
  }
  if (!["IN_BETA_TESTING", "READY_FOR_BETA_TESTING", "BETA_APPROVED", "READY_FOR_BETA_SUBMISSION",
    "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "IN_EXPORT_COMPLIANCE_REVIEW"].includes(state)) {
    return { ...selected, outcome: "blocked", reason: `Unsupported Apple external build state: ${state}` }
  }
  const alreadyAssigned = selected.groups.some((item) => item.id === EXTERNAL_GROUP)
  let changed = !alreadyAssigned
  if (!alreadyAssigned) {
    await api(`/v1/betaGroups/${EXTERNAL_GROUP}/relationships/builds`, {
      data: [{ type: "builds", id: selected.build }],
    })
  }
  const groups = await buildGroups(api, selected.build)
  if (!groups.some((item) => item.id === EXTERNAL_GROUP && item.attributes?.isInternalGroup === false)
      || !groups.some((item) => item.id === GROUP && item.attributes?.isInternalGroup === true)
      || groups.some((item) => item.attributes?.isInternalGroup === false && item.id !== EXTERNAL_GROUP)) {
    throw new Error("TestFlight group readback failed")
  }
  let current = await detail()
  // Approval must automatically start testing even when review outlives this Run.
  if (["READY_FOR_BETA_SUBMISSION", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"].includes(current.attributes.externalBuildState)
      && current.attributes.autoNotifyEnabled !== true) {
    if (!current.id) throw new Error("Missing selected build beta detail identity")
    await api(`/v1/buildBetaDetails/${current.id}`, { data: {
      type: "buildBetaDetails", id: current.id, attributes: { autoNotifyEnabled: true },
    } }, "PATCH")
    changed = true
    current = await detail()
    if (current.attributes.autoNotifyEnabled !== true) throw new Error("Automatic TestFlight notification readback failed")
  }
  if (current.attributes.externalBuildState === "READY_FOR_BETA_SUBMISSION" && !review) {
    await api("/v1/betaAppReviewSubmissions", { data: {
      type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: selected.build } } },
    } })
    changed = true
  }
  let after = (await detail()).attributes
  const finalReviews = await list(api, `/v1/betaAppReviewSubmissions?filter[build]=${selected.build}&limit=200`)
  const finalReview = finalReviews[0]?.attributes?.betaReviewState
  if (blocked.includes(after.externalBuildState) || finalReview === "REJECTED") {
    return { ...selected, outcome: "blocked", reason: `group assigned; Apple requires action: ${after.externalBuildState} (beta review ${finalReview || "none"})` }
  }
  // Group assignment alone does not start already-approved external testing.
  if (["READY_FOR_BETA_TESTING", "BETA_APPROVED"].includes(after.externalBuildState)) {
    try {
      await api("/v1/buildBetaNotifications", { data: {
        type: "buildBetaNotifications", relationships: { build: { data: { type: "builds", id: selected.build } } },
      } })
    } catch (error) {
      // Automatic start can race this request, or Apple can lose its response.
      // Read the exact build back instead of retrying a tester notification.
      if ((await detail()).attributes.externalBuildState !== "IN_BETA_TESTING") throw error
    }
    changed = true
    after = (await detail()).attributes
  }
  if (blocked.includes(after.externalBuildState)) {
    return { ...selected, outcome: "blocked", reason: `group assigned; Apple requires action: ${after.externalBuildState}` }
  }
  if (after.externalBuildState === "IN_BETA_TESTING") {
    return { ...selected, outcome: changed ? "published" : "already-current", reason: "external Early Users group verified; IN_BETA_TESTING" }
  }
  return { ...selected, outcome: "deferred", reason: `group assigned; Apple state ${after.externalBuildState} (beta review ${finalReview || "not yet visible"}); external availability not confirmed` }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const result = await promoteTestFlight({ api: appleClient(process.env), isPublished: internalPublication(),
      qualify: (sha) => execFileSync("python3", ["scripts/ci/nightly-tip-gate.py", "qualify"], {
        env: { ...process.env, EXPECTED_SHA: sha }, stdio: "inherit",
      }),
    })
    console.log(`iOS TestFlight ${result.outcome}: build ${result.version}, source ${result.sha}; ${result.reason}`)
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT,
      `outcome=${result.outcome}\nreason=${result.reason}\nbuild=${result.version}\nsha=${result.sha}\n`)
    if (result.outcome === "blocked") process.exitCode = 1
  } catch (error) {
    console.error(error instanceof Error ? error.message : "iOS TestFlight promotion failed")
    process.exitCode = 1
  }
}
