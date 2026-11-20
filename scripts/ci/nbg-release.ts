#!/usr/bin/env bun
// Coolify owns host access and image pulls. CI only pins an immutable GHCR
// image, queues a deployment, and verifies its health and direct user paths.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs"
import { isIP } from "node:net"
import { annotate, failed, probeCredentials, readReady, smoke } from "./release-smoke"

const SHA = /^[0-9a-f]{40}$/
const IMAGE = /^(ghcr\.io\/inline-chat\/inline-server)@(sha256:[0-9a-f]{64})$/
const ID = /^[a-zA-Z0-9_-]+$/
const terminal = new Set(["finished", "failed", "cancelled", "cancelled-by-user", "error"])
type Json = Record<string, unknown>
export type Api = (method: "GET" | "POST" | "PATCH", path: string, body?: Json) => Promise<unknown>
export type NbgConfig = { sha: string; image: string; imageName: string; imageTag: string; ip: string; app: string; url: string; token: string }
export type NbgBaseline = { app: string; imageName: string; imageTag: string; revision: string }
export type NbgReceipt = { app: string; sha: string; image: string; deployment: string }
type Hooks = { ready?: (revision?: string) => Promise<string>; verify?: () => Promise<void>; pause?: (ms: number) => Promise<void>; now?: () => number; save?: (receipt: NbgReceipt) => void }

function object(value: unknown, label: string): Json {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`Invalid ${label} response`)
  return value as Json
}

export function config(env: Record<string, string | undefined>): NbgConfig {
  const need = (name: string) => {
    const value = env[name]
    if (!value) throw new Error(`${name} is required`)
    return value
  }
  const sha = need("RELEASE_SHA")
  if (!SHA.test(sha)) throw new Error("RELEASE_SHA must be a full commit SHA")
  const image = need("STANDBY_IMAGE")
  const match = IMAGE.exec(image)
  if (!match) throw new Error("STANDBY_IMAGE must be an immutable inline-server GHCR digest")
  const ip = need("NBG_ORIGIN_IP")
  if (!isIP(ip)) throw new Error("NBG_ORIGIN_IP must be an IP address")
  const app = need("COOLIFY_APP_UUID")
  if (!ID.test(app)) throw new Error("Invalid COOLIFY_APP_UUID")
  const url = new URL(need("COOLIFY_URL"))
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("COOLIFY_URL must be an https origin without credentials or a path")
  }
  // Both older and newer Coolify releases join these fields with ':'. This
  // shape therefore pins a digest without relying on newer sha256-tag handling.
  return { sha, image, imageName: `${match[1]}@sha256`, imageTag: match[2]!.slice("sha256:".length),
    ip, app, url: url.origin, token: need("COOLIFY_TOKEN") }
}

export function client(c: NbgConfig, fetcher: (url: string, init: RequestInit) => Promise<Response> = fetch): Api {
  return async (method, path, body) => {
    let response: Response
    try {
      response = await fetcher(`${c.url}/api/v1/${path}`, { method, redirect: "error", signal: AbortSignal.timeout(30_000),
        headers: { Authorization: `Bearer ${c.token}`, Accept: "application/json", "Content-Type": "application/json" },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
    } catch {
      throw new Error(`Coolify ${method} ${path} request failed`)
    }
    // Provider bodies can contain environment/configuration values; never echo them.
    if (!response.ok) throw new Error(`Coolify ${method} ${path} returned HTTP ${response.status}`)
    try { return await response.json() } catch { throw new Error(`Coolify ${method} ${path} returned invalid JSON`) }
  }
}

async function state(api: Api, c: NbgConfig) {
  const value = object(await api("GET", `applications/${c.app}`), "application")
  const domains = typeof value.fqdn === "string" ? value.fqdn.split(",") : []
  const servesApi = domains.some((domain) => {
    try { const url = new URL(domain.trim()); return url.protocol === "https:" && url.hostname === "api.inline.chat" } catch { return false }
  })
  if (value.uuid !== c.app || value.build_pack !== "dockerimage" || value.health_check_enabled !== true ||
      value.health_check_path !== "/readyz" || String(value.health_check_port) !== "8000" || !servesApi) {
    throw new Error("Coolify must target the api.inline.chat Docker Image app with /readyz health checks on port 8000")
  }
  if (typeof value.docker_registry_image_name !== "string" || typeof value.docker_registry_image_tag !== "string") {
    throw new Error("Coolify image configuration is unavailable")
  }
  return { imageName: value.docker_registry_image_name, imageTag: value.docker_registry_image_tag,
    healthy: value.status === "running:healthy" }
}

const same = (a: { imageName: string; imageTag: string }, b: { imageName: string; imageTag: string }) =>
  a.imageName === b.imageName && a.imageTag === b.imageTag

async function deployments(api: Api, c: NbgConfig) {
  const value = await api("GET", `deployments/applications/${c.app}`)
  const rows = Array.isArray(value) ? value : object(value, "deployments").deployments
  if (!Array.isArray(rows)) throw new Error("Coolify deployment list is unavailable")
  return rows.map((item) => object(item, "deployment"))
}

export async function preflight(api: Api, c: NbgConfig, ready = (revision?: string) => readReady(c.ip, revision)): Promise<NbgBaseline> {
  const before = await state(api, c)
  if (!before.healthy) throw new Error("Nuremberg must be healthy before recording its restore target")
  if ((await deployments(api, c)).some((item) => !terminal.has(String(item.status)))) {
    throw new Error("Nuremberg has a deployment in progress; wait before starting a release")
  }
  const revision = await ready()
  if (!SHA.test(revision)) throw new Error("Nuremberg readiness did not report a full revision")
  return { app: c.app, imageName: before.imageName, imageTag: before.imageTag, revision }
}

export async function release(api: Api, c: NbgConfig, previous: NbgBaseline, receipt?: NbgReceipt, hooks: Hooks = {}) {
  if (!previous || typeof previous !== "object" || previous.app !== c.app ||
      typeof previous.imageName !== "string" || !previous.imageName ||
      typeof previous.imageTag !== "string" || !previous.imageTag ||
      typeof previous.revision !== "string" || !SHA.test(previous.revision)) {
    throw new Error("A saved pre-mutation Nuremberg baseline is required")
  }
  if (receipt && (receipt.app !== c.app || receipt.sha !== c.sha || receipt.image !== c.image ||
      typeof receipt.deployment !== "string" || !ID.test(receipt.deployment))) {
    throw new Error("Saved Nuremberg deployment does not match this release")
  }
  const ready = hooks.ready ?? ((revision?: string) => readReady(c.ip, revision))
  const pause = hooks.pause ?? Bun.sleep
  const now = hooks.now ?? Date.now
  const before = await state(api, c)
  if (!same(before, previous) && !same(before, c)) throw new Error("Coolify image changed outside this release; refusing to overwrite it")
  const active = (await deployments(api, c)).filter((item) => !terminal.has(String(item.status)))
  if (active.some((item) => item.deployment_uuid !== receipt?.deployment)) {
    throw new Error("An unrecorded Coolify deployment is active; reconcile it before retrying")
  }
  const patch = async (image: { imageName: string; imageTag: string }) => {
    await api("PATCH", `applications/${c.app}`, { docker_registry_image_name: image.imageName, docker_registry_image_tag: image.imageTag })
    if (!same(await state(api, c), image)) throw new Error("Coolify did not retain the requested image pin")
  }
  let queueUnresolved = false
  const queue = async () => {
    queueUnresolved = true
    // Older Coolify versions read query parameters even on POST. Omitting
    // force keeps its false default across versions (the string "false" did not).
    const result = object(await api("POST", `deploy?uuid=${c.app}`), "deployment queue")
    const rows = result.deployments
    const item = Array.isArray(rows) && rows.length === 1 ? object(rows[0], "queued deployment") : {}
    if (typeof item.deployment_uuid !== "string" || !ID.test(item.deployment_uuid) ||
        (item.resource_uuid !== undefined && item.resource_uuid !== c.app)) throw new Error("Coolify did not queue this application's deployment")
    queueUnresolved = false
    return item.deployment_uuid
  }
  const status = async (id: string) => String(object(await api("GET", `deployments/${id}`), "deployment").status ?? "")
  const wait = async (id: string) => {
    const deadline = now() + 10 * 60_000
    let failures = 0
    for (let attempt = 0; attempt < 60 && now() < deadline; attempt++) {
      try {
        const current = await status(id)
        failures = 0
        if (terminal.has(current)) return current
      } catch (error) { if (++failures >= 3) throw error }
      await pause(10_000)
    }
    throw new Error("Coolify deployment timed out")
  }
  const verify = async (image: { imageName: string; imageTag: string }, revision: string) => {
    const deadline = now() + 2 * 60_000
    for (let attempt = 0; attempt < 25 && now() < deadline; attempt++) {
      const current = await state(api, c)
      if (!same(current, image)) throw new Error("Coolify image pin changed during deployment")
      if (current.healthy && await ready(revision).then(() => true, () => false)) return
      if (attempt < 24) await pause(5_000)
    }
    throw new Error("Nuremberg did not become healthy on the expected revision")
  }

  let deployment: string | undefined
  let resumed = false
  try {
    if (receipt && same(before, c)) deployment = receipt.deployment
    const recordedStatus = receipt && same(before, c) ? await status(receipt.deployment) : undefined
    if (receipt && recordedStatus && !["failed", "cancelled", "cancelled-by-user", "error"].includes(recordedStatus)) {
      deployment = receipt.deployment
      resumed = recordedStatus === "finished"
    } else {
      await patch(c)
      deployment = await queue()
      hooks.save?.({ app: c.app, sha: c.sha, image: c.image, deployment })
    }
    const result = await wait(deployment)
    if (result !== "finished") throw new Error(`Coolify deployment ${result}`)
    await verify(c, c.sha)
    await hooks.verify?.()
    return { outcome: resumed ? "already-current" : "published", deployment, image: c.image } as const
  } catch (error) {
    const reason = error instanceof Error ? error.message : "Nuremberg release failed"
    try {
      // Never race an active/unknown deployment with restoration. Stop the
      // recorded operation first; an ambiguous unrecorded queue needs inspection.
      if (queueUnresolved) throw new Error("deployment queue response is ambiguous")
      if (deployment && !terminal.has(await status(deployment))) {
        await api("POST", `deployments/${deployment}/cancel`)
        if (!terminal.has(await wait(deployment))) throw new Error("deployment cancellation was not confirmed")
      }
      if ((await deployments(api, c)).some((item) => !terminal.has(String(item.status)))) {
        throw new Error("a deployment is still active")
      }
      const actual = await state(api, c)
      if (!same(actual, c) && !same(actual, previous)) throw new Error("image changed outside this release")
      await patch(previous)
      const restoration = await queue()
      if (await wait(restoration) !== "finished") throw new Error("restore deployment failed")
      await verify(previous, previous.revision)
    } catch {
      throw new Error(`${reason}. Previous release was NOT verified restored; use the saved release plan to reconcile Coolify. Fly must remain unchanged.`)
    }
    throw new Error(`${reason}. Previous Coolify image and direct readiness were restored and verified.`)
  }
}

/**
 * rollback_to_plan: redeploy the pre-release Coolify image recorded by an earlier
 * release plan. Unlike release(), a failure does not restore the image being
 * replaced, because that is the release being rolled back. A recorded receipt
 * from an earlier attempt of this run is resumed instead of queuing again.
 */
export async function rollback(api: Api, c: NbgConfig, receipt?: NbgReceipt, hooks: Hooks = {}) {
  if (receipt && (receipt.app !== c.app || receipt.sha !== c.sha || receipt.image !== c.image ||
      typeof receipt.deployment !== "string" || !ID.test(receipt.deployment))) {
    throw new Error("Saved Nuremberg deployment does not match this rollback")
  }
  const ready = hooks.ready ?? ((revision?: string) => readReady(c.ip, revision))
  const pause = hooks.pause ?? Bun.sleep
  const now = hooks.now ?? Date.now
  const status = async (id: string) => String(object(await api("GET", `deployments/${id}`), "deployment").status ?? "")
  const wait = async (id: string) => {
    const deadline = now() + 10 * 60_000
    let failures = 0
    for (let attempt = 0; attempt < 60 && now() < deadline; attempt++) {
      try {
        const current = await status(id)
        failures = 0
        if (terminal.has(current)) return current
      } catch (error) { if (++failures >= 3) throw error }
      await pause(10_000)
    }
    throw new Error("Coolify deployment timed out")
  }
  const verify = async () => {
    const deadline = now() + 2 * 60_000
    for (let attempt = 0; attempt < 25 && now() < deadline; attempt++) {
      const current = await state(api, c)
      if (!same(current, c)) throw new Error("Coolify image pin changed during rollback")
      if (current.healthy && await ready(c.sha).then(() => true, () => false)) return
      if (attempt < 24) await pause(5_000)
    }
    throw new Error("Nuremberg did not become healthy on the rollback revision")
  }
  let deployment: string | undefined
  try {
    const before = await state(api, c)
    const active = (await deployments(api, c)).filter((item) => !terminal.has(String(item.status)))
    if (active.some((item) => item.deployment_uuid !== receipt?.deployment)) {
      throw new Error("An unrecorded Coolify deployment is active; cancel or finish it in Coolify, then rerun")
    }
    const recorded = receipt && same(before, c) ? await status(receipt.deployment) : undefined
    if (receipt && recorded && !["failed", "cancelled", "cancelled-by-user", "error"].includes(recorded)) {
      // An earlier attempt of this run queued it, so this run did roll back even when it already finished.
      deployment = receipt.deployment
    } else if (!receipt && same(before, c) && before.healthy && await ready(c.sha).then(() => true, () => false)) {
      // Already pinned, healthy and serving the recorded revision: verify only.
      await hooks.verify?.()
      return { outcome: "already-current", image: c.image } as const
    } else {
      await api("PATCH", `applications/${c.app}`, { docker_registry_image_name: c.imageName, docker_registry_image_tag: c.imageTag })
      if (!same(await state(api, c), c)) throw new Error("Coolify did not retain the rollback image pin")
      const queued = object(await api("POST", `deploy?uuid=${c.app}`), "deployment queue")
      const rows = queued.deployments
      const item = Array.isArray(rows) && rows.length === 1 ? object(rows[0], "queued deployment") : {}
      if (typeof item.deployment_uuid !== "string" || !ID.test(item.deployment_uuid) ||
          (item.resource_uuid !== undefined && item.resource_uuid !== c.app)) throw new Error("Coolify did not queue this application's rollback deployment")
      deployment = item.deployment_uuid
      hooks.save?.({ app: c.app, sha: c.sha, image: c.image, deployment })
    }
    const result = await wait(deployment)
    if (result !== "finished") throw new Error(`Coolify rollback deployment ${result}`)
    await verify()
    await hooks.verify?.()
    return { outcome: "published", deployment, image: c.image } as const
  } catch (error) {
    const reason = error instanceof Error ? error.message : "Nuremberg rollback failed"
    throw new Error(`${reason}. Nuremberg rollback did not complete${deployment ? ` (deployment ${deployment})` : ""}; ` +
      "Coolify may hold the rollback pin or the release being replaced. Reconcile it in Coolify; the Fly rollback is independent.")
  }
}

/** The recorded Coolify baseline as an immutable rollback target, or an explanation why it cannot be one. */
export function rollbackTarget(baseline: unknown, app: string): { image: string; revision: string } {
  const value = baseline !== null && typeof baseline === "object" && !Array.isArray(baseline) ? baseline as Json : undefined
  if (!value) throw new Error("The release plan recorded no Nuremberg baseline")
  if (value.app !== app) throw new Error("The recorded Nuremberg baseline belongs to another Coolify app")
  if (typeof value.revision !== "string" || !SHA.test(value.revision)) throw new Error("The recorded Nuremberg baseline has no full revision")
  const image = `${String(value.imageName)}:${String(value.imageTag)}`
  if (!IMAGE.test(image)) throw new Error("The recorded Nuremberg image is not an immutable inline-server GHCR digest; roll it back manually")
  return { image, revision: value.revision }
}

if (import.meta.main) {
  try {
    // A rollback targets the recorded baseline (rollback-plan.ts), checked against this job's Coolify app.
    const target = process.argv.includes("--rollback")
      ? rollbackTarget(JSON.parse(process.env.ROLLBACK_BASELINE || "null"), process.env.COOLIFY_APP_UUID ?? "") : undefined
    const c = config(target ? { ...process.env, RELEASE_SHA: target.revision, STANDBY_IMAGE: target.image } : process.env)
    const api = client(c)
    if (process.argv.includes("--preflight")) {
      const baseline = await preflight(api, c)
      writeFileSync(process.env.NBG_BASELINE_FILE!, JSON.stringify(baseline))
    } else if (process.argv.includes("--rollback")) {
      const stateFile = process.env.NBG_STATE_FILE!
      const receipt = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, "utf8")) as NbgReceipt : undefined
      const result = await rollback(api, c, receipt, {
        save: (value) => writeFileSync(stateFile, JSON.stringify(value)),
        verify: async () => {
          const checks = await smoke({ origin: "nuremberg", revision: c.sha, ip: c.ip,
            token: process.env.SMOKE_BOT_TOKEN ?? "", chatId: process.env.SMOKE_CHAT_ID ?? "",
            probes: probeCredentials(process.env), advisoryProbes: true })
          console.log(checks.map((check) => `${check.skipped ? "skip" : check.ok ? "pass" : check.advisory ? "WARN" : "FAIL"}: ${check.name}`).join("\n"))
          annotate("nuremberg", checks)
          if (failed(checks)) throw new Error("Nuremberg direct user-path smoke failed after rollback")
        },
      })
      if (result.outcome === "already-current") {
        console.log(`::warning title=Nothing to roll back on Nuremberg::It already serves the recorded baseline ${c.sha}; the selected plan may not be the release you meant (see rollback_plan_run).`)
      }
      if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `outcome=${result.outcome}\n`)
    } else {
      const plan = object(JSON.parse(readFileSync(process.env.RELEASE_PLAN!, "utf8")), "release plan")
      if (plan.sha !== c.sha || plan.standby_image !== c.image) throw new Error("Saved release plan differs from the qualified image")
      const stateFile = process.env.NBG_STATE_FILE!
      const receipt = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, "utf8")) as NbgReceipt : undefined
      const result = await release(api, c, plan.nuremberg as NbgBaseline, receipt, {
        save: (value) => writeFileSync(stateFile, JSON.stringify(value)),
        verify: async () => {
          const checks = await smoke({ origin: "nuremberg", revision: c.sha, ip: c.ip,
            token: process.env.SMOKE_BOT_TOKEN ?? "", chatId: process.env.SMOKE_CHAT_ID ?? "",
            probes: probeCredentials(process.env), advisoryProbes: process.env.INLINE_SMOKE_PROBES === "advisory" })
          console.log(checks.map((check) => `${check.skipped ? "skip" : check.ok ? "pass" : check.advisory ? "WARN" : "FAIL"}: ${check.name}`).join("\n"))
          annotate("nuremberg", checks)
          if (failed(checks)) throw new Error("Nuremberg direct user-path smoke failed")
        },
      })
      if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `outcome=${result.outcome}\ndeployment=${result.deployment}\n`)
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : "Nuremberg release failed")
    process.exitCode = 1
  }
}
