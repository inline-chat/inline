import { describe, expect, it } from "bun:test"
import { client, config, preflight, release, type Api, type NbgBaseline, type NbgReceipt } from "./nbg-release"

const SHA = "a".repeat(40)
const OLD_SHA = "c".repeat(40)
const DIGEST = `sha256:${"b".repeat(64)}`
const env = {
  RELEASE_SHA: SHA, STANDBY_IMAGE: `ghcr.io/inline-chat/inline-server@${DIGEST}`,
  NBG_ORIGIN_IP: "203.0.113.7", COOLIFY_URL: "https://coolify.example/",
  COOLIFY_TOKEN: "fixture-secret", COOLIFY_APP_UUID: "app1",
}
const previous: NbgBaseline = { app: "app1", imageName: "127.0.0.1:5000/inline-api", imageTag: "release-old-1", revision: OLD_SHA }
const desired = () => ({ imageName: config(env).imageName, imageTag: config(env).imageTag })
type Image = { imageName: string; imageTag: string }
type Outcome = { status: string; healthy?: boolean; revision?: string; failReads?: number }
type Deployment = Outcome & Image & { deployment_uuid: string; applied?: boolean }

// A small controller model: a queued deployment retains its own image; reading
// an old finished deployment cannot run it again or overwrite a later restore.
function provider(options: {
  configured?: Image; revision?: string; healthy?: boolean; outcomes?: Outcome[];
  listShape?: "array" | "object"; appOverrides?: Record<string, unknown>;
  loseQueueAck?: boolean; hideDeployments?: boolean; cancelFails?: boolean;
} = {}) {
  const host = { ...(options.configured ?? previous), revision: options.revision ?? OLD_SHA, healthy: options.healthy ?? true }
  const calls: Array<{ method: string; path: string; body?: Record<string, unknown> }> = []
  const rows = new Map<string, Deployment>()
  let queues = 0
  const api: Api = async (method, path, body) => {
    calls.push({ method, path, body })
    if (path === "applications/app1" && method === "GET") return {
      uuid: "app1", fqdn: "https://api.inline.chat", build_pack: "dockerimage", health_check_enabled: true,
      health_check_path: "/readyz", health_check_port: "8000", status: host.healthy ? "running:healthy" : "running:unhealthy",
      docker_registry_image_name: host.imageName, docker_registry_image_tag: host.imageTag,
      ...options.appOverrides,
    }
    if (path === "applications/app1" && method === "PATCH") {
      host.imageName = String(body?.docker_registry_image_name)
      host.imageTag = String(body?.docker_registry_image_tag)
      return {}
    }
    if (path === "deployments/applications/app1") {
      const deployments = options.hideDeployments ? [] : [...rows.values()].map(({ deployment_uuid, status }) => ({ deployment_uuid, status }))
      return options.listShape === "array" ? deployments : { deployments }
    }
    if (path === "deploy?uuid=app1" && method === "POST") {
      expect(body).toBeUndefined()
      const id = `deployment-${++queues}`
      const outcome = options.outcomes?.[queues - 1] ?? { status: "finished" }
      rows.set(id, { ...host, ...outcome, healthy: outcome.healthy ?? true,
        revision: outcome.revision ?? (host.imageTag === desired().imageTag ? SHA : previous.revision), deployment_uuid: id })
      if (options.loseQueueAck) throw new Error("queue acknowledgement unavailable")
      return { deployments: [{ deployment_uuid: id, resource_uuid: "app1" }] }
    }
    const match = /^deployments\/([a-zA-Z0-9_-]+)(\/cancel)?$/.exec(path)
    if (match) {
      const row = rows.get(match[1]!)
      if (!row) throw new Error("unknown deployment")
      if (match[2] && method === "POST") {
        if (options.cancelFails) throw new Error("cancellation unavailable")
        row.status = "cancelled-by-user"
        return { status: row.status }
      }
      if (row.failReads) { row.failReads--; throw new Error("status unavailable") }
      if (row.status === "finished" && !row.applied) {
        Object.assign(host, { imageName: row.imageName, imageTag: row.imageTag, revision: row.revision, healthy: row.healthy ?? true })
        row.applied = true
      }
      return { deployment_uuid: row.deployment_uuid, status: row.status }
    }
    throw new Error(`Unexpected API route ${method} ${path}`)
  }
  const ready = async (revision?: string) => {
    if (!host.healthy || (revision && host.revision !== revision)) throw new Error("direct readiness did not match")
    return host.revision
  }
  const receipt = (id = "prior-deployment", outcome: Outcome = { status: "finished" }): NbgReceipt => {
    rows.set(id, { ...desired(), ...outcome, revision: SHA, deployment_uuid: id })
    return { app: "app1", sha: SHA, image: env.STANDBY_IMAGE, deployment: id }
  }
  return { api, host, calls, rows, ready, receipt, queued: () => queues,
    patches: () => calls.filter((call) => call.method === "PATCH").map((call) => call.body) }
}
const pause = async () => {}

describe("Nuremberg release API boundary", () => {
  it("bounds slow status polling by elapsed time so restoration has time to run", async () => {
    const f = provider({ outcomes: [{ status: "in_progress" }, { status: "finished" }] })
    let elapsed = 0
    const slow: Api = async (method, path, body) => {
      if (method === "GET" && path === "deployments/deployment-1" && f.rows.get("deployment-1")?.status === "in_progress") elapsed += 30_000
      return f.api(method, path, body)
    }
    await expect(release(slow, config(env), previous, undefined, {
      ready: f.ready, now: () => elapsed, pause: async (ms) => { elapsed += ms },
    })).rejects.toThrow("timed out")
    expect(f.calls.filter((call) => call.method === "GET" && call.path === "deployments/deployment-1").length).toBeLessThan(20)
    expect(f.host.imageName).toBe(previous.imageName)
    expect(f.host.imageTag).toBe(previous.imageTag)
    expect(f.host.revision).toBe(previous.revision)
  })

  it("uses the version-compatible immutable digest representation without SSH or registry credentials", () => {
    expect(config(env)).toMatchObject({ imageName: "ghcr.io/inline-chat/inline-server@sha256", imageTag: "b".repeat(64), ip: "203.0.113.7", url: "https://coolify.example" })
    expect(config(env)).not.toHaveProperty("flyToken")
    expect(config(env)).not.toHaveProperty("sshHost")
  })

  it("captures a healthy original image and revision without changing the controller", async () => {
    for (const listShape of ["array", "object"] as const) {
      const f = provider({ listShape })
      expect(await preflight(f.api, config(env), f.ready)).toEqual(previous)
      expect(f.calls.every((call) => call.method === "GET")).toBe(true)
    }
  })

  it("blocks preflight when the origin is unhealthy, misconfigured or busy", async () => {
    const cases = [
      provider({ healthy: false }), provider({ appOverrides: { build_pack: "dockerfile" } }),
      provider({ appOverrides: { uuid: "another-app" } }), provider({ appOverrides: { health_check_enabled: false } }),
      provider({ appOverrides: { health_check_port: "9000" } }),
      provider({ appOverrides: { fqdn: "https://another.example" } }),
    ]
    const busy = provider()
    busy.receipt("unrelated", { status: "in_progress" })
    cases.push(busy)
    for (const f of cases) {
      await expect(preflight(f.api, config(env), f.ready)).rejects.toThrow()
      expect(f.patches()).toEqual([])
    }
    const malformed = provider()
    await expect(preflight(malformed.api, config(env), async () => "not-a-revision")).rejects.toThrow("revision")
    expect(malformed.patches()).toEqual([])
  })

  it("pins and verifies the qualified image, and saves the deployment identity before polling", async () => {
    const f = provider()
    const saved: NbgReceipt[] = []
    let verified = 0
    const result = await release(f.api, config(env), previous, undefined, {
      ready: f.ready, pause, save: (value) => { saved.push(value) },
      verify: async () => { verified++; expect(f.host.revision).toBe(SHA) },
    })
    expect(result).toMatchObject({ outcome: "published", image: env.STANDBY_IMAGE, deployment: "deployment-1" })
    expect(saved).toEqual([{ app: "app1", sha: SHA, image: env.STANDBY_IMAGE, deployment: "deployment-1" }])
    expect(f.patches()).toEqual([{ docker_registry_image_name: desired().imageName, docker_registry_image_tag: desired().imageTag }])
    expect(verified).toBe(1)
  })

  it("deploys despite the same source revision when the configured digest differs", async () => {
    const oldDigest = { ...previous, imageName: "ghcr.io/inline-chat/inline-server@sha256", imageTag: "d".repeat(64), revision: SHA }
    const f = provider({ configured: oldDigest, revision: SHA })
    expect((await release(f.api, config(env), oldDigest, undefined, { ready: f.ready, pause })).outcome).toBe("published")
    expect(f.queued()).toBe(1)
    expect(f.host.imageTag).toBe(desired().imageTag)
  })

  it("requires its own finished receipt before reporting an existing target as current", async () => {
    const f = provider({ configured: desired(), revision: SHA })
    const receipt = f.receipt()
    let verified = 0
    expect((await release(f.api, config(env), previous, receipt, { ready: f.ready, pause, verify: async () => { verified++ } })).outcome).toBe("already-current")
    expect(f.queued()).toBe(0)
    expect(f.patches()).toEqual([])
    expect(verified).toBe(1)
    const unknown = provider({ configured: desired(), revision: SHA })
    expect((await release(unknown.api, config(env), previous, undefined, { ready: unknown.ready, pause })).outcome).toBe("published")
    expect(unknown.queued()).toBe(1)
  })

  it("resumes a recorded deployment without queuing a second one", async () => {
    const f = provider({ configured: desired(), revision: OLD_SHA })
    const receipt = f.receipt("queued-before-interruption", { status: "in_progress" })
    let pauses = 0
    const result = await release(f.api, config(env), previous, receipt, {
      ready: f.ready, pause: async () => { pauses++; f.rows.get(receipt.deployment)!.status = "finished" },
    })
    expect(result.deployment).toBe(receipt.deployment)
    expect(pauses).toBe(1)
    expect(f.queued()).toBe(0)
    expect(f.host.revision).toBe(SHA)
  })

  it("retains the original restore target after an interrupted configuration switch", async () => {
    const f = provider({ configured: desired(), outcomes: [{ status: "failed" }, { status: "finished" }] })
    await expect(release(f.api, config(env), previous, undefined, { ready: f.ready, pause })).rejects.toThrow("restored and verified")
    expect(f.patches().at(-1)).toEqual({ docker_registry_image_name: previous.imageName, docker_registry_image_tag: previous.imageTag })
    expect(f.queued()).toBe(2)
    expect(f.host).toMatchObject({ imageName: previous.imageName, imageTag: previous.imageTag, revision: previous.revision, healthy: true })
  })

  it("redeploys and verifies the previous image after health or user-path verification fails", async () => {
    for (const mode of ["health", "smoke", "wrong revision"] as const) {
      const f = provider({ outcomes: [
        { status: "finished", healthy: mode !== "health", revision: mode === "wrong revision" ? OLD_SHA : SHA },
        { status: "finished" },
      ] })
      await expect(release(f.api, config(env), previous, undefined, {
        ready: f.ready, pause, verify: async () => { if (mode === "smoke") throw new Error("smoke failed") },
      })).rejects.toThrow("restored and verified")
      expect(f.queued()).toBe(2)
      expect(f.host.revision).toBe(OLD_SHA)
      expect(f.host.imageName).toBe(previous.imageName)
    }
  })

  it("never claims restoration when the restore deployment fails", async () => {
    const f = provider({ outcomes: [{ status: "failed" }, { status: "failed" }] })
    await expect(release(f.api, config(env), previous, undefined, { ready: f.ready, pause })).rejects.toThrow("NOT verified restored")
  })

  it("refuses missing, malformed and mismatched saved baselines before mutation", async () => {
    const baselines: unknown[] = [undefined, null, {}, { ...previous, app: "other" }, { ...previous, revision: "short" },
      { ...previous, imageName: 7 }, { ...previous, imageTag: 7 }, { ...previous, imageName: "" }]
    for (const baseline of baselines) {
      const f = provider({ configured: desired() })
      await expect(release(f.api, config(env), baseline as NbgBaseline, undefined, { ready: f.ready, pause })).rejects.toThrow("baseline")
      expect(f.patches()).toEqual([])
    }
  })

  it("refuses mismatched receipts and independent image changes", async () => {
    const receipts = [
      { app: "other" }, { sha: OLD_SHA }, { image: "ghcr.io/inline-chat/inline-server:latest" }, { deployment: "bad/id" },
    ]
    for (const change of receipts) {
      const f = provider()
      await expect(release(f.api, config(env), previous, { ...f.receipt(), ...change }, { ready: f.ready, pause })).rejects.toThrow("does not match")
      expect(f.patches()).toEqual([])
    }
    const drift = provider({ configured: { imageName: "operator/another-image", imageTag: "manual" } })
    await expect(release(drift.api, config(env), previous, undefined, { ready: drift.ready, pause })).rejects.toThrow("outside this release")
    expect(drift.patches()).toEqual([])
  })

  it("blocks ambiguous queue acknowledgement even if the next deployment-list read is stale", async () => {
    const f = provider({ loseQueueAck: true, hideDeployments: true })
    await expect(release(f.api, config(env), previous, undefined, { ready: f.ready, pause })).rejects.toThrow("NOT verified restored")
    expect(f.patches()).toHaveLength(1)
    expect(f.host.imageTag).toBe(desired().imageTag)
  })

  it("does not restore while a known deployment's status or cancellation is unresolved", async () => {
    const unknown = provider({ outcomes: [{ status: "in_progress", failReads: 100 }] })
    await expect(release(unknown.api, config(env), previous, undefined, { ready: unknown.ready, pause })).rejects.toThrow("NOT verified restored")
    expect(unknown.patches()).toHaveLength(1)
    const uncancellable = provider({ outcomes: [{ status: "in_progress" }], cancelFails: true })
    await expect(release(uncancellable.api, config(env), previous, undefined, { ready: uncancellable.ready, pause })).rejects.toThrow("NOT verified restored")
    expect(uncancellable.patches()).toHaveLength(1)
    const resumed = provider({ configured: desired(), hideDeployments: true })
    const receipt = resumed.receipt("recorded-before-interruption", { status: "in_progress", failReads: 100 })
    await expect(release(resumed.api, config(env), previous, receipt, { ready: resumed.ready, pause })).rejects.toThrow("NOT verified restored")
    expect(resumed.patches()).toEqual([])
  })

  it("cancels a stuck recorded deployment before restoring its predecessor", async () => {
    const f = provider({ outcomes: [{ status: "in_progress" }, { status: "finished" }] })
    await expect(release(f.api, config(env), previous, undefined, { ready: f.ready, pause })).rejects.toThrow("restored and verified")
    const cancel = f.calls.findIndex((call) => call.path === "deployments/deployment-1/cancel")
    const restore = f.calls.findIndex((call) => call.body?.docker_registry_image_name === previous.imageName)
    expect(cancel).toBeGreaterThan(0)
    expect(restore).toBeGreaterThan(cancel)
    expect(f.host.revision).toBe(OLD_SHA)
  })

  it("rejects mutable images and malformed inputs without contacting any provider", () => {
    for (const change of [{ STANDBY_IMAGE: "ghcr.io/inline-chat/inline-server:latest" }, { RELEASE_SHA: "short" },
      { NBG_ORIGIN_IP: "not-an-address" }, { COOLIFY_APP_UUID: "app/../other" }, { COOLIFY_URL: "http://coolify.example" },
      { COOLIFY_URL: "https://user:password@coolify.example/" }, { COOLIFY_URL: "https://coolify.example/api/v1/" }, { COOLIFY_TOKEN: "" }]) {
      expect(() => config({ ...env, ...change })).toThrow()
    }
  })

  it("sends API credentials only as headers and hides provider bodies and transport errors", async () => {
    const seen: Array<{ url: string; init: RequestInit }> = []
    const api = client(config(env), async (url, init) => { seen.push({ url, init }); return Response.json({ uuid: "app1" }) })
    expect(await api("GET", "applications/app1")).toEqual({ uuid: "app1" })
    expect(seen[0]!.url).not.toContain(env.COOLIFY_TOKEN)
    expect(seen[0]!.init).toMatchObject({ redirect: "error", headers: { Authorization: `Bearer ${env.COOLIFY_TOKEN}` } })
    for (const fetcher of [
      async () => new Response(`DATABASE_URL=hidden ${env.COOLIFY_TOKEN}`, { status: 500 }),
      async () => new Response(`invalid JSON ${env.COOLIFY_TOKEN}`),
      async () => { throw new Error(`private transport error ${env.COOLIFY_TOKEN}`) },
    ]) {
      let message = ""
      try { await client(config(env), fetcher)("GET", "applications/app1") } catch (error) { message = (error as Error).message }
      expect(message).toContain("Coolify GET applications/app1")
      expect(message).not.toContain(env.COOLIFY_TOKEN)
      expect(message).not.toContain("DATABASE_URL")
      expect(message).not.toContain("private transport")
    }
  })
})
