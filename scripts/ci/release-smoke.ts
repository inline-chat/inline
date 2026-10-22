#!/usr/bin/env bun
// Live smoke test for one API origin after a release. It pins api.inline.chat
// to the origin's own address (curl --resolve) so each origin is checked
// directly, not whichever one Cloudflare happens to route to.
//
// Checks: /readyz is ok and serves the expected revision, the smoke bot
// authenticates, a message sent to the dedicated smoke chat reads back, and
// both realtime paths accept a WebSocket upgrade.
//
// Env: SMOKE_BOT_TOKEN, SMOKE_CHAT_ID (a private chat with only the smoke bot).
// --preflight only reads readiness, bot identity and smoke-chat history.
// Usage: release-smoke.ts --origin <name> --revision <sha> [--ip <address>] [--preflight]
import { appendFileSync } from "node:fs"
import { isIP } from "node:net"
import { parseArgs } from "node:util"

const HOST = "api.inline.chat"
const SHA = /^[0-9a-f]{40}$/

export type Curl = (args: string[], options?: { token?: string }) => Promise<{ code: number; body: string }>

export const curl: Curl = async (args, options = {}) => {
  if (options.token && /[\r\n]/.test(options.token)) throw new Error("Invalid smoke bot token")
  // -H @- reads headers from stdin; the token never enters the process argv.
  // Disable ambient curl config and proxies so --resolve tests the origin.
  const child = Bun.spawn(["curl", "--disable", "--noproxy", "*", "-sS", "--max-time", "15", "-w", "\n%{http_code}",
    ...(options.token ? ["-H", "@-"] : []), ...args], {
    stdin: options.token ? new TextEncoder().encode(`Authorization: Bearer ${options.token}\n`) : "ignore",
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

export type SmokeOptions = {
  origin: string
  revision?: string
  ip?: string
  token: string
  chatId: string
  curl?: Curl
  now?: () => number
  preflight?: boolean
}

export type SmokeCheck = { name: string; ok: boolean; detail: string }

export async function smoke(options: SmokeOptions): Promise<SmokeCheck[]> {
  if ((!options.preflight || options.revision !== undefined) && !SHA.test(options.revision ?? "")) throw new Error("--revision must be a full commit SHA")
  if (!options.token || /[\r\n]/.test(options.token) || !/^[1-9]\d*$/.test(options.chatId) || !positiveId(Number(options.chatId))) {
    throw new Error("SMOKE_BOT_TOKEN and a valid SMOKE_CHAT_ID are required")
  }
  const run = options.curl ?? curl
  const pinned = pin(options.ip)
  const checks: SmokeCheck[] = []
  const check = async (name: string, body: () => Promise<string>) => {
    try {
      checks.push({ name, ok: true, detail: await body() })
      return true
    } catch (error) {
      checks.push({ name, ok: false, detail: error instanceof Error ? error.message : String(error) })
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
  return checks
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
  })
  const lines = checks.map((c) => `- ${c.ok ? "✅" : "❌"} ${c.name}: ${c.detail}`)
  console.log(lines.join("\n"))
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `#### Smoke: ${values.origin}\n\n${lines.join("\n")}\n\n`)
  }
  if (checks.some((c) => !c.ok)) process.exitCode = 1
}
