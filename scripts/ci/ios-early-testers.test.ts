import { describe, expect, it } from "bun:test"
import { generateKeyPairSync, verify } from "node:crypto"
import { APP, GROUP, WORKFLOW, appleClient, ensureSourceTag, makeToken, publish, reusableRun } from "./ios-early-testers.mjs"

const sha = "a".repeat(40)
const run = { id: "run", attributes: { sourceCommit: { commitSha: sha }, executionProgress: "COMPLETE", completionStatus: "SUCCEEDED" } }
const group = { id: GROUP, attributes: { isInternalGroup: true } }
const build = { id: "build", attributes: { version: "42", processingState: "VALID", buildAudienceType: "APP_STORE_ELIGIBLE", expired: false } }

function fixture(overrides: Record<string, unknown> = {}) {
  let groups: unknown[] = []
  const mutations: Array<{ path: string; data: unknown }> = []
  const routes: Record<string, unknown> = {
    [`/v1/betaGroups/${GROUP}`]: group,
    [`/v1/betaGroups/${GROUP}/app`]: { id: APP },
    [`/v1/ciWorkflows/${WORKFLOW}/buildRuns?sort=-number&limit=100`]: [run],
    "/v1/ciBuildRuns/run": run,
    "/v1/ciBuildRuns/run/builds?limit=200": [build],
    "/v1/builds/build": build,
    "/v1/builds/build/app": { id: APP },
    "/v1/builds/build/preReleaseVersion": { attributes: { platform: "IOS", version: "0.1" } },
    "/v1/builds/build/individualTesters?limit=200": [],
    ...overrides,
  }
  const api = async (path: string, data?: unknown) => {
    if (data) {
      mutations.push({ path, data })
      groups = [group]
      return {}
    }
    if (path.startsWith("/v1/betaGroups?")) return { data: groups }
    if (!(path in routes)) throw new Error(`Unexpected request: ${path}`)
    return { data: routes[path] }
  }
  return { api, mutations, setGroups: (value: unknown[]) => { groups = value } }
}

describe("internal iOS release boundary", () => {
  it("reuses a successful exact-source build and only adds Early Testers", async () => {
    const f = fixture()
    let gates = 0
    const result = await publish({ api: f.api, sha, qualify: () => { gates++ }, log: () => {} })
    expect(result.build).toBe("build")
    expect(gates).toBe(2)
    expect(f.mutations).toEqual([{ path: `/v1/betaGroups/${GROUP}/relationships/builds`, data: { data: [{ type: "builds", id: "build" }] } }])
  })
  it("is idempotent when the exact build is already internal", async () => {
    const f = fixture()
    f.setGroups([group])
    await publish({ api: f.api, sha, qualify: () => {}, log: () => {} })
    expect(f.mutations).toEqual([])
  })
  it("rejects external groups, wrong app/platform/source, expired builds and individual assignments", async () => {
    const cases = [
      { [`/v1/betaGroups/${GROUP}`]: { ...group, attributes: { isInternalGroup: false } } },
      { "/v1/builds/build/app": { id: "other" } },
      { "/v1/builds/build/preReleaseVersion": { attributes: { platform: "MAC_OS" } } },
      { "/v1/ciBuildRuns/run": { ...run, attributes: { ...run.attributes, sourceCommit: { commitSha: "b".repeat(40) } } } },
      { "/v1/builds/build": { ...build, attributes: { ...build.attributes, expired: true } } },
      { "/v1/builds/build/individualTesters?limit=200": [{ id: "tester" }] },
    ]
    for (const overrides of cases) {
      const f = fixture(overrides)
      await expect(publish({ api: f.api, sha, qualify: () => {}, log: () => {} })).rejects.toThrow()
      expect(f.mutations).toEqual([])
    }
    const f = fixture()
    f.setGroups([{ id: "external", attributes: { isInternalGroup: false } }])
    await expect(publish({ api: f.api, sha, qualify: () => {}, log: () => {} })).rejects.toThrow("external distribution")
    expect(f.mutations).toEqual([])
  })
  it("does not distribute when main advances during the build", async () => {
    const f = fixture()
    let gates = 0
    await expect(publish({ api: f.api, sha, qualify: () => { if (++gates === 2) throw new Error("main moved") }, log: () => {} })).rejects.toThrow("main moved")
    expect(f.mutations).toEqual([])
  })
  it("does not reuse failed runs or runs from another commit", () => {
    expect(reusableRun([{ ...run, attributes: { ...run.attributes, completionStatus: "FAILED" } }], sha)).toBeUndefined()
    expect(reusableRun([run], "b".repeat(40))).toBeUndefined()
    expect(reusableRun([{ ...run, attributes: { ...run.attributes, executionProgress: "RUNNING" } }], sha)).toBeDefined()
  })
  it("creates an immutable source tag and refuses to move an existing tag", async () => {
    const env = { GITHUB_REPOSITORY: "inline-chat/inline", GH_TOKEN: "test-token" }
    const calls: Array<{ url: string; body?: string }> = []
    const fetcher = async (url: string, options: { body?: string }) => {
      calls.push({ url, body: options.body })
      return calls.length === 1 ? new Response("", { status: 404 })
        : Response.json({ object: { sha, type: "commit" } }, { status: 201 })
    }
    expect(await ensureSourceTag(sha, env, fetcher)).toBe(`refs/tags/ios-early-testers/${sha}`)
    expect(JSON.parse(calls[1].body!)).toEqual({ ref: `refs/tags/ios-early-testers/${sha}`, sha })
    await expect(ensureSourceTag(sha, env, async () => Response.json({ object: { sha: "b".repeat(40), type: "commit" } }))).rejects.toThrow("Existing source tag differs")
  })
  it("starts Apple from the immutable tag and resumes until the exact archive is ready", async () => {
    const f = fixture({ [`/v1/ciWorkflows/${WORKFLOW}/buildRuns?sort=-number&limit=100`]: [] })
    const mutations: unknown[] = []
    const api = async (path: string, data?: unknown) => {
      if (path.includes("/gitReferences?")) return { data: [{ id: "tag-ref", attributes: { canonicalName: `refs/tags/ios-early-testers/${sha}` } }] }
      if (path === "/v1/ciBuildRuns" && data) { mutations.push(data); return { data: run } }
      return f.api(path, data)
    }
    await publish({ api, sha, qualify: () => {}, sourceTag: async () => `refs/tags/ios-early-testers/${sha}`, log: () => {} })
    expect(mutations).toEqual([{ data: { type: "ciBuildRuns", relationships: {
      workflow: { data: { type: "ciWorkflows", id: WORKFLOW } },
      sourceBranchOrTag: { data: { type: "scmGitReferences", id: "tag-ref" } },
    } } }])
    expect(f.mutations.length).toBe(1)
  })
  it("signs short lived Apple JWTs without disclosing credentials to pagination hosts", async () => {
    const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
    const env = { ASC_KEY_ID: "id", ASC_ISSUER_ID: "issuer", ASC_PRIVATE_KEY: pair.privateKey.export({ type: "pkcs8", format: "pem" }).toString() }
    const jwt = makeToken(env, 1000)
    const [header, payload, signature] = jwt.split(".")
    expect(JSON.parse(Buffer.from(payload, "base64url").toString())).toMatchObject({ iat: 1000, exp: 1600, aud: "appstoreconnect-v1" })
    expect(verify("sha256", Buffer.from(`${header}.${payload}`), { key: pair.publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"))).toBe(true)
    let requests = 0
    const api = appleClient(env, async () => { requests++; return new Response("", { status: 204 }) })
    await expect(api("https://example.com/v1/stolen")).rejects.toThrow("Unexpected Apple API URL")
    expect(requests).toBe(0)
  })
})
