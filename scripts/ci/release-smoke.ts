#!/usr/bin/env bun
// Live smoke test for one API origin after a release. It pins api.inline.chat
// to the origin's own address (curl --resolve) so each origin is checked
// directly, not whichever one Cloudflare happens to route to.
//
// Checks: /readyz is ok and serves the expected revision, the smoke bot
// authenticates, a message sent to the dedicated smoke chat reads back, and
// both realtime paths accept a WebSocket upgrade.
//
// Against a pinned origin (--ip) the release also probes one success path per
// route family when its credential is configured, and skips it with a visible
// notice otherwise: /v1 identity and a small /v1 upload (INLINE_SMOKE_USER_TOKEN),
// OAuth introspection (INLINE_SMOKE_MCP_SECRET, plus INLINE_SMOKE_OAUTH_TOKEN for
// the active-grant contract, which is always advisory because the token expires). The V3 protocol probe needs the SDK and lives in
// release-smoke-v3.ts. INLINE_SMOKE_PROBES=advisory reports probe failures as
// warnings (incident dispatches with skip_gate); the base checks always gate.
//
// Env: SMOKE_BOT_TOKEN, SMOKE_CHAT_ID (a private chat with only the smoke bot).
// --preflight only reads readiness, bot identity and smoke-chat history; it never
// runs the route-family probes, so a broken production route cannot block its fix.
// Usage: release-smoke.ts --origin <name> --revision <sha> [--ip <address>] [--preflight]
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { isIP } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { parseArgs } from "node:util"

const HOST = "api.inline.chat"
const SHA = /^[0-9a-f]{40}$/

export type CurlOptions = { token?: string; headers?: string[] }
export type Curl = (args: string[], options?: CurlOptions) => Promise<{ code: number; body: string }>

export const curl: Curl = async (args, options = {}) => {
  if (options.token && /[\r\n]/.test(options.token)) throw new Error("Invalid smoke bot token")
  if (options.headers?.some((header) => /[\r\n]/.test(header))) throw new Error("Invalid smoke header")
  // -H @- reads headers from stdin; credentials never enter the process argv.
  // Disable ambient curl config and proxies so --resolve tests the origin.
  const headers = [...(options.token ? [`Authorization: Bearer ${options.token}`] : []), ...(options.headers ?? [])]
  const child = Bun.spawn(["curl", "--disable", "--noproxy", "*", "-sS", "--max-time", "15", "-w", "\n%{http_code}",
    ...(headers.length ? ["-H", "@-"] : []), ...args], {
    stdin: headers.length ? new TextEncoder().encode(headers.map((header) => `${header}\n`).join("")) : "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  })
  const [output, , code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ])
  const split = output.lastIndexOf("\n")
  const status = Number(output.slice(split + 1)) || 0
  // An upgraded WebSocket remains open until curl's bounded timeout.
  if (code !== 0 && status !== 101) throw new Error(`curl transport failed (exit ${code})`)
  return { code: status, body: output.slice(0, split) }
}

const object = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value)
const positiveId = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value > 0

function pin(ip?: string): string[] {
  if (!ip) return []
  const version = isIP(ip)
  if (!version) throw new Error("--ip must be an IPv4 or IPv6 address")
  return ["--resolve", `${HOST}:443:${version === 6 ? `[${ip}]` : ip}`]
}

async function json(run: Curl, args: string[], token?: string): Promise<Record<string, unknown>> {
  const response = await run(args, token ? { token } : undefined)
  if (response.code !== 200) throw new Error(`HTTP ${response.code}`)
  let value: unknown
  try { value = JSON.parse(response.body) } catch { throw new Error("Invalid JSON response") }
  if (!object(value) || value.ok !== true) throw new Error("API request was not successful")
  return value
}

export async function readReady(ip?: string, revision?: string, run: Curl = curl): Promise<string> {
  if (revision !== undefined && !SHA.test(revision)) throw new Error("--revision must be a full commit SHA")
  const ready = await json(run, [...pin(ip), `https://${HOST}/readyz`])
  if (ready.draining !== false) throw new Error("not ready or draining")
  if (typeof ready.revision !== "string" || !SHA.test(ready.revision)) throw new Error("readiness returned no full revision")
  if (revision && ready.revision !== revision) throw new Error(`serves ${ready.revision.slice(0, 9)}`)
  return ready.revision
}

/** Route-family probe credentials; each absent credential skips its probes. */
export type ProbeCredentials = {
  /** Session token of a dedicated non-bot smoke user (/v1 identity and upload). */
  userToken?: string
  /** The server's MCP_INTERNAL_SHARED_SECRET, sent as x-inline-mcp-secret. */
  mcpSecret?: string
  /** An active access token of the dedicated smoke OAuth grant. */
  oauthToken?: string
}

export type SmokeOptions = {
  origin: string
  revision?: string
  ip?: string
  token: string
  chatId: string
  curl?: Curl
  now?: () => number
  preflight?: boolean
  probes?: ProbeCredentials
  /** Report probe failures as advisory instead of failing the smoke. */
  advisoryProbes?: boolean
  scratch?: string
}

export type SmokeCheck = { name: string; ok: boolean; detail: string; skipped?: boolean; advisory?: boolean }

/** A smoke fails on any failed check except advisory probe failures. */
export const failed = (checks: SmokeCheck[]) => checks.some((check) => !check.ok && !check.advisory)

export function probeCredentials(env: Record<string, string | undefined>): ProbeCredentials {
  return {
    userToken: env.INLINE_SMOKE_USER_TOKEN || undefined,
    mcpSecret: env.INLINE_SMOKE_MCP_SECRET || undefined,
    oauthToken: env.INLINE_SMOKE_OAUTH_TOKEN || undefined,
  }
}

async function response(run: Curl, args: string[], options?: CurlOptions): Promise<{ code: number; value: Record<string, unknown> }> {
  const reply = await run(args, options)
  let value: unknown
  // Never echo a body: an introspection body carries the grant's Inline token.
  try { value = JSON.parse(reply.body) } catch { throw new Error(`HTTP ${reply.code} with an invalid JSON body`) }
  if (!object(value)) throw new Error(`HTTP ${reply.code} with a non-object body`)
  return { code: reply.code, value }
}

const nonEmpty = (value: unknown): value is string => typeof value === "string" && value.length > 0
const idString = (value: unknown): value is string => typeof value === "string" && /^[1-9]\d*$/.test(value)

/** Exactly the fields the MCP server consumes from OAuthIntrospectionResult. */
export function checkIntrospection(value: Record<string, unknown>, nowSeconds: number): string {
  const missing: string[] = []
  if (value.active !== true) missing.push("active")
  for (const field of ["grant_id", "client_id", "scope", "aud", "inline_token"]) if (!nonEmpty(value[field])) missing.push(field)
  if (!idString(value.inline_user_id)) missing.push("inline_user_id")
  if (!Number.isSafeInteger(value.exp) || (value.exp as number) <= nowSeconds) missing.push("exp")
  if (!Array.isArray(value.space_ids) || !value.space_ids.every(idString)) missing.push("space_ids")
  for (const field of ["allow_dms", "allow_home_threads"]) if (typeof value[field] !== "boolean") missing.push(field)
  if (value.via_app !== undefined && typeof value.via_app !== "string") missing.push("via_app")
  if (value.allow_unsigned !== undefined && typeof value.allow_unsigned !== "boolean") missing.push("allow_unsigned")
  if (missing.length) throw new Error(`introspection contract mismatch: ${missing.join(", ")}`)
  return "active grant matches the introspection contract"
}

export async function smoke(options: SmokeOptions): Promise<SmokeCheck[]> {
  if ((!options.preflight || options.revision !== undefined) && !SHA.test(options.revision ?? "")) throw new Error("--revision must be a full commit SHA")
  if (!options.token || /[\r\n]/.test(options.token) || !/^[1-9]\d*$/.test(options.chatId) || !positiveId(Number(options.chatId))) {
    throw new Error("SMOKE_BOT_TOKEN and a valid SMOKE_CHAT_ID are required")
  }
  for (const [name, value] of Object.entries(options.probes ?? {})) {
    if (value !== undefined && (!value || /[\r\n]/.test(value))) throw new Error(`Invalid ${name} probe credential`)
  }
  const run = options.curl ?? curl
  const pinned = pin(options.ip)
  const checks: SmokeCheck[] = []
  const check = async (name: string, body: () => Promise<string>, advisory = false) => {
    try {
      checks.push({ name, ok: true, detail: await body() })
      return true
    } catch (error) {
      checks.push({ name, ok: false, detail: error instanceof Error ? error.message : String(error), ...(advisory ? { advisory } : {}) })
      return false
    }
  }
  const authenticated = (args: string[]) => json(run, [...pinned, ...args], options.token)
  const history = async () => {
    const value = await authenticated([`https://${HOST}/bot/getChatHistory?chat_id=${options.chatId}&limit=10`])
    if (!object(value.result) || !Array.isArray(value.result.messages)) throw new Error("getChatHistory returned no message list")
    return value.result.messages as unknown[]
  }

  if (!await check("readiness", async () => `ready on ${(await readReady(options.ip, options.revision, run)).slice(0, 9)}`)) return checks
  if (!await check("bot login", async () => {
    const me = await authenticated([`https://${HOST}/bot/getMe`])
    const user = object(me.result) && object(me.result.user) ? me.result.user : undefined
    if (!user || !positiveId(user.id) || user.is_bot !== true) throw new Error("getMe returned no authenticated bot identity")
    return `authenticated as bot ${user.id}`
  })) return checks
  if (options.preflight) {
    await check("chat access", async () => { await history(); return "smoke chat history is accessible" })
    return checks
  }
  await check("send and read back", async () => {
    const marker = `release smoke ${options.origin} ${options.revision!.slice(0, 9)} ${(options.now ?? Date.now)()}`
    const sent = await authenticated(["-H", "Content-Type: application/json",
      "--data", JSON.stringify({ chat_id: Number(options.chatId), text: marker }),
      `https://${HOST}/bot/sendMessage`])
    const message = object(sent.result) && object(sent.result.message) ? sent.result.message : undefined
    const id = message?.message_id
    if (!positiveId(id)) throw new Error("sendMessage returned no message id")
    const found = (await history()).some((message) => object(message) && message.message_id === id && message.text === marker)
    if (!found) throw new Error(`message ${id} missing from history`)
    return `message ${id} round-tripped`
  })
  for (const path of ["/realtime", "/realtime/v3"]) {
    await check(`websocket ${path}`, async () => {
      // A 101 proves the origin upgrades the socket; the session protocol is covered by CI.
      const response = await run([...pinned, "--http1.1", "--max-time", "5",
        "-H", "Connection: Upgrade", "-H", "Upgrade: websocket", "-H", "Sec-WebSocket-Version: 13",
        "-H", `Sec-WebSocket-Key: ${Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64")}`,
        "-o", "/dev/null", `https://${HOST}${path}`])
      if (response.code !== 101) throw new Error(`upgrade returned HTTP ${response.code}`)
      return "upgraded"
    })
  }
  // Route families are probed per pinned origin; canonical routing is not re-probed.
  if (options.ip) await probe(options, run, pinned, checks, check)
  return checks
}

type Check = (name: string, body: () => Promise<string>, advisory?: boolean) => Promise<boolean>

async function probe(options: SmokeOptions, run: Curl, pinned: string[], checks: SmokeCheck[], check: Check) {
  const credentials = options.probes ?? {}
  const advisory = options.advisoryProbes === true
  const skip = (name: string, secret: string) => checks.push({ name, ok: true, skipped: true, detail: `skipped: ${secret} is not configured` })

  if (!credentials.userToken) {
    skip("v1 getMe", "INLINE_SMOKE_USER_TOKEN")
    skip("v1 upload", "INLINE_SMOKE_USER_TOKEN")
  } else {
    const token = credentials.userToken
    await check("v1 getMe", async () => {
      const me = await json(run, [...pinned, "-X", "POST", "-H", "Content-Type: application/json", "--data", "{}",
        `https://${HOST}/v1/getMe`], token)
      const user = object(me.result) && object(me.result.user) ? me.result.user : undefined
      if (!user || !positiveId(user.id)) throw new Error("getMe returned no user identity")
      return `authenticated as user ${user.id}`
    }, advisory)
    await check("v1 upload", async () => {
      const directory = mkdtempSync(join(options.scratch ?? tmpdir(), "inline-smoke-upload-"))
      try {
        const file = join(directory, "release-smoke.txt")
        writeFileSync(file, `release smoke ${options.origin} ${options.revision!.slice(0, 9)} ${(options.now ?? Date.now)()}\n`)
        const uploaded = await json(run, [...pinned, "-F", "type=document",
          "-F", `file=@${file};type=text/plain;filename=release-smoke.txt`, `https://${HOST}/v1/uploadFile`], token)
        const result = object(uploaded.result) ? uploaded.result : undefined
        if (!result || !nonEmpty(result.fileUniqueId) || !positiveId(result.documentId)) throw new Error("uploadFile returned no document identity")
        return `document ${result.documentId} stored`
      } finally { rmSync(directory, { recursive: true, force: true }) }
    }, advisory)
  }

  if (!credentials.mcpSecret) {
    skip("oauth introspection", "INLINE_SMOKE_MCP_SECRET")
    return
  }
  const secret = [`x-inline-mcp-secret: ${credentials.mcpSecret}`, "Content-Type: application/json"]
  const introspect = async (token: string) => {
    // The token travels in a private body file, never in argv.
    const directory = mkdtempSync(join(options.scratch ?? tmpdir(), "inline-smoke-oauth-"))
    try {
      const body = join(directory, "body.json")
      writeFileSync(body, JSON.stringify({ token }), { mode: 0o600 })
      return await response(run, [...pinned, "--data-binary", `@${body}`, `https://${HOST}/oauth/introspect`], { headers: secret })
    } finally { rmSync(directory, { recursive: true, force: true }) }
  }
  await check("oauth introspection (inactive token)", async () => {
    // An unknown token proves the route, the shared secret and the grant lookup.
    const reply = await introspect(`mcp_at_release_smoke_${crypto.randomUUID().replaceAll("-", "")}`)
    if (reply.code !== 401 || reply.value.active !== false || Object.keys(reply.value).length !== 1) {
      throw new Error(`expected HTTP 401 {active:false}, got HTTP ${reply.code}`)
    }
    return "unknown token reported inactive"
  }, advisory)
  if (!credentials.oauthToken) {
    skip("oauth introspection (active grant)", "INLINE_SMOKE_OAUTH_TOKEN")
    return
  }
  // Always advisory: a stored access token expires after about two hours and
  // refresh tokens rotate, so this cannot gate until a long-lived smoke grant exists.
  await check("oauth introspection (active grant)", async () => {
    const reply = await introspect(credentials.oauthToken!)
    if (reply.code !== 200) throw new Error(`HTTP ${reply.code}`)
    return checkIntrospection(reply.value, Math.floor((options.now ?? Date.now)() / 1000))
  }, true)
}

export function report(checks: SmokeCheck[]): string[] {
  return checks.map((c) => `- ${c.skipped ? "⚪" : c.ok ? "✅" : c.advisory ? "⚠️" : "❌"} ${c.name}: ${c.detail}${c.advisory ? " (advisory)" : ""}`)
}

/** Skipped and advisory probes surface on the run page, not only in logs. */
export function annotate(origin: string, checks: SmokeCheck[], log = console.log) {
  for (const check of checks) {
    if (check.skipped) log(`::notice title=Smoke probe skipped (${origin})::${check.name}: ${check.detail}`)
    else if (!check.ok && check.advisory) log(`::warning title=Smoke probe failed, advisory (${origin})::${check.name}: ${check.detail}`)
  }
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { origin: { type: "string" }, revision: { type: "string" }, ip: { type: "string" }, preflight: { type: "boolean" } } })
  const checks = await smoke({
    origin: values.origin ?? "canonical",
    revision: values.revision,
    ip: values.ip || undefined,
    token: process.env.SMOKE_BOT_TOKEN ?? "",
    chatId: process.env.SMOKE_CHAT_ID ?? "",
    preflight: values.preflight,
    probes: probeCredentials(process.env),
    advisoryProbes: process.env.INLINE_SMOKE_PROBES === "advisory",
  })
  const lines = report(checks)
  console.log(lines.join("\n"))
  annotate(values.origin ?? "canonical", checks)
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `#### Smoke: ${values.origin}\n\n${lines.join("\n")}\n\n`)
  }
  if (failed(checks)) process.exitCode = 1
}
