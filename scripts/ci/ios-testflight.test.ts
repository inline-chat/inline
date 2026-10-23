import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { generateKeyPairSync } from "node:crypto"
import { parse } from "yaml"
import { APP, GROUP, WORKFLOW, appleClient } from "./ios-early-testers.mjs"
import { EXTERNAL_GROUP, internalPublication, promoteTestFlight, selectInternalBuild } from "./ios-testflight.mjs"

const sha = "a".repeat(40)
const now = Date.parse("2026-10-23T00:00:00Z")
const run = { id: "run", attributes: { number: 1362, sourceCommit: { commitSha: sha }, executionProgress: "COMPLETE", completionStatus: "SUCCEEDED" } }
const internal = { id: GROUP, attributes: { isInternalGroup: true } }
const external = { id: EXTERNAL_GROUP, attributes: { isInternalGroup: false } }
const build = { id: "build", attributes: { version: "1362", processingState: "VALID", expired: false,
  expirationDate: "2027-01-20T00:00:00Z", buildAudienceType: "APP_STORE_ELIGIBLE" } }

function fixture({ state = "READY_FOR_BETA_TESTING", assigned = false, review = undefined as string | undefined,
  overrides = {} as Record<string, unknown>, readbackFails = false, rejectReview = false,
  autoNotify = true, notificationReadbackFails = false, startReadbackFails = false, notificationResponseLost = false } = {}) {
  const mutations: Array<{ path: string; data: unknown; method?: string }> = []
  let externalState = state
  let reviewState = review
  let externalAssigned = assigned
  let autoNotifyEnabled = autoNotify
  const routes: Record<string, unknown> = {
    [`/v1/betaGroups/${EXTERNAL_GROUP}`]: external,
    [`/v1/betaGroups/${EXTERNAL_GROUP}/app`]: { id: APP },
    [`/v1/ciWorkflows/${WORKFLOW}/buildRuns?sort=-number&limit=100`]: [run],
    "/v1/ciBuildRuns/run": run,
    "/v1/ciBuildRuns/run/builds?limit=200": [build],
    "/v1/builds/build": build,
    "/v1/builds/build/app": { id: APP },
    "/v1/builds/build/preReleaseVersion": { attributes: { version: "0.1", platform: "IOS" } },
    "/v1/builds/build/individualTesters?limit=200": [],
    [`/v1/apps/${APP}/betaGroups?limit=200`]: [internal, external],
    [`/v1/betaGroups/${GROUP}/relationships/builds?limit=200`]: [{ id: "build" }],
    ...overrides,
  }
  const api = async (path: string, data?: unknown, method?: string): Promise<{ data: any }> => {
    if (data) {
      mutations.push({ path, data, ...(method ? { method } : {}) })
      if (path === `/v1/betaGroups/${EXTERNAL_GROUP}/relationships/builds`) {
        externalAssigned = !readbackFails
        // Assignment alone never starts the build in this fixture.
      } else if (path === "/v1/buildBetaDetails/detail") {
        expect(method).toBe("PATCH")
        autoNotifyEnabled = !notificationReadbackFails
      } else if (path === "/v1/betaAppReviewSubmissions") {
        reviewState = rejectReview ? "REJECTED" : "WAITING_FOR_REVIEW"
        externalState = rejectReview ? "BETA_REJECTED" : "WAITING_FOR_BETA_REVIEW"
      } else if (path === "/v1/buildBetaNotifications") {
        expect(["READY_FOR_BETA_TESTING", "BETA_APPROVED"]).toContain(externalState)
        if (!startReadbackFails) externalState = "IN_BETA_TESTING"
        if (notificationResponseLost) throw new Error("notification response lost")
      } else throw new Error(`Unexpected mutation: ${path}`)
      return { data: {} }
    }
    if (Object.hasOwn(routes, path)) return { data: routes[path] }
    if (path === `/v1/betaGroups/${EXTERNAL_GROUP}/relationships/builds?limit=200`) return { data: externalAssigned ? [{ id: "build" }] : [] }
    if (path === "/v1/builds/build/buildBetaDetail") return { data: { id: "detail", attributes: { externalBuildState: externalState, autoNotifyEnabled } } }
    if (path === "/v1/betaAppReviewSubmissions?filter[build]=build&limit=200") return { data: reviewState ? [{ attributes: { betaReviewState: reviewState } }] : [] }
    throw new Error(`Unexpected request: ${path}`)
  }
  const options = { api, now, isPublished: async () => true, qualify: async (value: string) => { expect(value).toBe(sha) } }
  return { api, mutations, options }
}

describe("manual iOS TestFlight promotion", () => {
  it("promotes the exact published internal build and is idempotent on another Run", async () => {
    const f = fixture({ autoNotify: false })
    expect(await promoteTestFlight(f.options)).toMatchObject({ outcome: "published", sha, run: "run", build: "build", version: "1362" })
    expect(f.mutations).toEqual([
      { path: `/v1/betaGroups/${EXTERNAL_GROUP}/relationships/builds`, data: { data: [{ type: "builds", id: "build" }] } },
      { path: "/v1/buildBetaNotifications", data: { data: { type: "buildBetaNotifications",
        relationships: { build: { data: { type: "builds", id: "build" } } } } } },
    ])
    expect(await promoteTestFlight(f.options)).toMatchObject({ outcome: "already-current" })
    expect(f.mutations).toHaveLength(2)
  })

  it("submits beta review once and reports pending approval without claiming availability", async () => {
    const f = fixture({ state: "READY_FOR_BETA_SUBMISSION", autoNotify: false })
    const result = await promoteTestFlight(f.options)
    expect(result.outcome).toBe("deferred")
    expect(result.reason).toContain("WAITING_FOR_REVIEW")
    expect(result.reason).toContain("external availability not confirmed")
    expect(f.mutations).toEqual([
      { path: `/v1/betaGroups/${EXTERNAL_GROUP}/relationships/builds`, data: { data: [{ type: "builds", id: "build" }] } },
      { path: "/v1/buildBetaDetails/detail", method: "PATCH", data: { data: { type: "buildBetaDetails", id: "detail", attributes: { autoNotifyEnabled: true } } } },
      { path: "/v1/betaAppReviewSubmissions", data: { data: { type: "betaAppReviewSubmissions",
        relationships: { build: { data: { type: "builds", id: "build" } } } } } },
    ])
    expect((await promoteTestFlight(f.options)).outcome).toBe("deferred")
    expect(f.mutations).toHaveLength(3)
  })

  it("starts an already-approved assigned build, but never notifies an active build again", async () => {
    const f = fixture({ state: "BETA_APPROVED", assigned: true, review: "APPROVED", autoNotify: false })
    expect((await promoteTestFlight(f.options)).outcome).toBe("published")
    expect(f.mutations.map((item) => item.path)).toEqual(["/v1/buildBetaNotifications"])
    expect((await promoteTestFlight(f.options)).outcome).toBe("already-current")
    expect(f.mutations).toHaveLength(1)
  })

  it("enables automatic notification for an existing pending review without resubmitting it", async () => {
    const f = fixture({ state: "WAITING_FOR_BETA_REVIEW", assigned: true, review: "WAITING_FOR_REVIEW", autoNotify: false })
    expect((await promoteTestFlight(f.options)).outcome).toBe("deferred")
    expect(f.mutations.map((item) => ({ path: item.path, method: item.method }))).toEqual([{ path: "/v1/buildBetaDetails/detail", method: "PATCH" }])
    expect((await promoteTestFlight(f.options)).outcome).toBe("deferred")
    expect(f.mutations).toHaveLength(1)
  })

  it("requires automatic-notification readback before review, and testing readback after start", async () => {
    const pending = fixture({ state: "READY_FOR_BETA_SUBMISSION", autoNotify: false, notificationReadbackFails: true })
    await expect(promoteTestFlight(pending.options)).rejects.toThrow("notification readback")
    expect(pending.mutations.map((item) => item.path)).toEqual([`/v1/betaGroups/${EXTERNAL_GROUP}/relationships/builds`, "/v1/buildBetaDetails/detail"])
    const ready = fixture({ startReadbackFails: true })
    const result = await promoteTestFlight(ready.options)
    expect(result.outcome).toBe("deferred")
    expect(result.reason).toContain("external availability not confirmed")
    expect(ready.mutations.map((item) => item.path)).toContain("/v1/buildBetaNotifications")
  })

  it("reconciles a lost start response without retrying, and surfaces an unconfirmed failure", async () => {
    const f = fixture({ assigned: true, notificationResponseLost: true })
    expect((await promoteTestFlight(f.options)).outcome).toBe("published")
    expect((await promoteTestFlight(f.options)).outcome).toBe("already-current")
    expect(f.mutations.map((item) => item.path)).toEqual(["/v1/buildBetaNotifications"])
    const failed = fixture({ assigned: true, notificationResponseLost: true, startReadbackFails: true })
    await expect(promoteTestFlight(failed.options)).rejects.toThrow("notification response lost")
    expect(failed.mutations).toHaveLength(1)
  })

  it("does not resubmit an existing review while Apple's external state catches up", async () => {
    const f = fixture({ state: "READY_FOR_BETA_SUBMISSION", review: "WAITING_FOR_REVIEW", assigned: true })
    expect((await promoteTestFlight(f.options)).outcome).toBe("deferred")
    expect(f.mutations).toEqual([])
  })

  it("reports rejected/compliance/unknown states as blocked before audience changes", async () => {
    for (const state of ["BETA_REJECTED", "MISSING_EXPORT_COMPLIANCE", "EXPIRED", "PROCESSING_EXCEPTION", "NOT_APPLICABLE", "NEW_UNKNOWN_STATE"]) {
      const f = fixture({ state, autoNotify: false })
      expect((await promoteTestFlight(f.options)).outcome).toBe("blocked")
      expect(f.mutations).toEqual([])
    }
    const f = fixture({ state: "READY_FOR_BETA_SUBMISSION", review: "REJECTED" })
    expect((await promoteTestFlight(f.options)).outcome).toBe("blocked")
    expect(f.mutations).toEqual([])
    const rejectedDuringSubmission = fixture({ state: "READY_FOR_BETA_SUBMISSION", rejectReview: true })
    expect((await promoteTestFlight(rejectedDuringSubmission.options)).outcome).toBe("blocked")
  })

  it("selects the newest published successful archive, skipping failed and unpublished newer runs", async () => {
    const failed = { ...run, id: "failed", attributes: { ...run.attributes, number: 1364, completionStatus: "FAILED" } }
    const unpublished = { ...run, id: "unpublished", attributes: { ...run.attributes, number: 1363 } }
    const older = { ...run, id: "older", attributes: { ...run.attributes, number: 1361 } }
    const f = fixture({ overrides: {
      [`/v1/ciWorkflows/${WORKFLOW}/buildRuns?sort=-number&limit=100`]: [failed, unpublished, run, older],
      "/v1/ciBuildRuns/unpublished/builds?limit=200": [{ id: "unpublished-build" }],
    } })
    const checked: string[] = []
    const result = await selectInternalBuild({ ...f.options, isPublished: async (_sha: string, build: string) => {
      checked.push(build)
      return build === "build"
    } })
    expect(result.build).toBe("build")
    expect(checked).toEqual(["unpublished-build", "build"])
    expect(f.mutations).toEqual([])
  })

  it("rejects wrong source/app/platform/group, unqualified sources and invalid/expired builds before writes", async () => {
    const cases = [
      { [`/v1/betaGroups/${EXTERNAL_GROUP}`]: { ...external, attributes: { isInternalGroup: true } } },
      { [`/v1/betaGroups/${EXTERNAL_GROUP}/app`]: { id: "wrong-app" } },
      { "/v1/builds/build/app": { id: "wrong-app" } },
      { "/v1/builds/build/preReleaseVersion": { attributes: { platform: "MAC_OS" } } },
      { "/v1/ciBuildRuns/run": { ...run, attributes: { ...run.attributes, sourceCommit: { commitSha: "b".repeat(40) } } } },
      { [`/v1/betaGroups/${GROUP}/relationships/builds?limit=200`]: [] },
      { "/v1/builds/build/individualTesters?limit=200": [{ id: "individual" }] },
      { [`/v1/apps/${APP}/betaGroups?limit=200`]: [internal, external, { id: "other-external", attributes: { isInternalGroup: false } }],
        "/v1/betaGroups/other-external/relationships/builds?limit=200": [{ id: "build" }] },
      ...[{ expired: true }, { processingState: "PROCESSING" }, { expirationDate: "2026-10-01T00:00:00Z" }, { expirationDate: "invalid" }, { buildAudienceType: "INTERNAL_ONLY" }]
        .map((attributes) => ({ "/v1/builds/build": { ...build, attributes: { ...build.attributes, ...attributes } } })),
    ]
    for (const overrides of cases) {
      const f = fixture({ overrides })
      await expect(promoteTestFlight(f.options)).rejects.toThrow()
      expect(f.mutations).toEqual([])
    }
    const f = fixture()
    await expect(promoteTestFlight({ ...f.options, isPublished: async () => false })).rejects.toThrow("No valid")
    await expect(promoteTestFlight({ ...f.options, qualify: async () => { throw new Error("source no longer green") } })).rejects.toThrow("no longer green")
    expect(f.mutations).toEqual([])
  })

  it("fails a missing group readback and does not continue to beta review", async () => {
    const f = fixture({ state: "READY_FOR_BETA_SUBMISSION", readbackFails: true, autoNotify: false })
    await expect(promoteTestFlight(f.options)).rejects.toThrow("readback")
    expect(f.mutations.map((item) => item.path)).toEqual([`/v1/betaGroups/${EXTERNAL_GROUP}/relationships/builds`])
  })

  it("requires an exact-build Actions receipt from a successfully completed internal lane", async () => {
    const env = { GITHUB_REPOSITORY: "inline-chat/inline", GH_TOKEN: "test-token" }
    const receipt = { context: "ios/early-testers", state: "success", description: "Early Testers build build",
      creator: { login: "github-actions[bot]" }, target_url: "https://github.com/inline-chat/inline/actions/runs/123" }
    // The internal lane can select a qualified source behind its workflow head.
    const publisher = { status: "completed", conclusion: "success", head_branch: "main", head_sha: "b".repeat(40), path: ".github/workflows/ios-early-testers.yml" }
    const verify = (status = receipt, run = publisher) => internalPublication(env, async (url: string) =>
      Response.json(url.includes("/statuses?") ? [status] : run))(sha, "build")
    expect(await verify()).toBe(true)
    for (const status of [
      { ...receipt, state: "pending" }, { ...receipt, description: "Early Testers build other" },
      { ...receipt, creator: { login: "other" } }, { ...receipt, target_url: "https://example.com/runs/123" },
    ]) expect(await verify(status)).toBe(false)
    for (const run of [{ ...publisher, conclusion: "failure" }, { ...publisher, status: "in_progress" },
      { ...publisher, path: ".github/workflows/other.yml" }, { ...publisher, head_branch: "feature" }]) expect(await verify(receipt, run)).toBe(false)
    const missing = internalPublication(env, async () => Response.json([]))
    expect(await missing(sha, "build")).toBe(false)
  })

  it("keeps Run manual/main-only in apple with read-only GitHub permissions and no release inputs", () => {
    const workflow = parse(readFileSync(new URL("../../.github/workflows/ios-testflight.yml", import.meta.url), "utf8"))
    expect(Object.keys(workflow.on)).toEqual(["workflow_dispatch"])
    expect(workflow.on.workflow_dispatch?.inputs).toBeUndefined()
    expect(workflow.jobs.release.environment).toBe("apple")
    expect(workflow.jobs.release.if).toContain("refs/heads/main")
    expect(Object.values(workflow.permissions).every((value) => value === "read")).toBe(true)
    expect(workflow.jobs.release.steps.filter((step: any) => step.env?.ASC_PRIVATE_KEY)).toHaveLength(1)
  })

  it("supports scoped PATCH requests while preserving the existing Apple client's GET/POST defaults", async () => {
    const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
    const env = { ASC_KEY_ID: "test", ASC_ISSUER_ID: "test",
      ASC_PRIVATE_KEY: pair.privateKey.export({ type: "pkcs8", format: "pem" }).toString() }
    const requests: Array<{ url: string; method: string; body?: string }> = []
    const api = appleClient(env, async (url: URL, options: { method: string; body?: string }) => {
      requests.push({ url: url.toString(), method: options.method, body: options.body })
      return new Response(null, { status: 204 })
    })
    await api("/v1/builds/build")
    await api("/v1/buildBetaNotifications", { data: { type: "buildBetaNotifications" } })
    const patch = { data: { type: "buildBetaDetails", id: "detail", attributes: { autoNotifyEnabled: true } } }
    await api("/v1/buildBetaDetails/detail", patch, "PATCH")
    expect(requests.map((item) => item.method)).toEqual(["GET", "POST", "PATCH"])
    expect(JSON.parse(requests[2].body!)).toEqual(patch)
    await expect(api("/v1/buildBetaDetails/detail", patch, "DELETE")).rejects.toThrow("Unexpected Apple API method")
    await expect(api("/v1/buildBetaDetails/detail", patch, "GET")).rejects.toThrow("Unexpected Apple API method")
    await expect(api("/v1/buildBetaDetails/detail", undefined, "PATCH")).rejects.toThrow("Unexpected Apple API method")
    await expect(api("https://example.com/v1/buildBetaDetails/detail", patch, "PATCH")).rejects.toThrow("Unexpected Apple API URL")
    expect(requests).toHaveLength(3)
  })
})
