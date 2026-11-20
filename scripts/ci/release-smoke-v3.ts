#!/usr/bin/env bun
// Inline Protocol (V3) release probe for one pinned origin. release-smoke.ts
// proves only the HTTP 101 upgrade on /realtime/v3; this runs the protocol:
//
// - handshake: obfuscated carrier, RSA-signed DH key exchange for a temporary
//   key against the production key ring, then an encrypted ping/pong. Needs no
//   credential, so it always runs.
// - getMe RPC: binds that temporary key to the dedicated smoke user's permanent
//   key (INLINE_SMOKE_V3_CREDENTIALS) and calls GET_ME. Skipped with a notice
//   when the credential is absent.
//
// It imports the SDK and protocol sources lazily, so callers need
// `bun install` and a built packages/protocol (the deploy step does both).
//
// Usage:
//   release-smoke-v3.ts --origin <name> --ip <address> [--credentials-stdin]
//   (the credential is read from INLINE_SMOKE_V3_CREDENTIALS, or from stdin with
//   --credentials-stdin so it never appears in a process argv or environment listing)
//   release-smoke-v3.ts --login <email>   (interactive: prints the credential JSON)
import { appendFileSync } from "node:fs"
import { createRequire } from "node:module"
import { isIP } from "node:net"
import { checkServerIdentity } from "node:tls"
import { parseArgs } from "node:util"
import { annotate, failed, report, type SmokeCheck } from "./release-smoke"

const HOST = "api.inline.chat"
const SDK = new URL("../../packages/sdk/src/realtime/", import.meta.url)
const PROTOCOL = new URL("../../packages/protocol/src/core.ts", import.meta.url)

/** Only the permanent key and its id are needed to bind a fresh temporary key. */
export type PermanentCredential = { key: Uint8Array; keyId: Uint8Array }

export function parseCredential(value: string | undefined): PermanentCredential | undefined {
  if (!value) return undefined
  let parsed: unknown
  try { parsed = JSON.parse(value) } catch { throw new Error("INLINE_SMOKE_V3_CREDENTIALS must be JSON") }
  const record = typeof parsed === "object" && parsed !== null ? parsed as Record<string, unknown> : {}
  const bytes = (field: string, length: number) => {
    const encoded = record[field]
    if (typeof encoded !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw new Error(`INLINE_SMOKE_V3_CREDENTIALS.${field} must be base64`)
    const decoded = Uint8Array.from(Buffer.from(encoded, "base64"))
    if (decoded.length !== length) throw new Error(`INLINE_SMOKE_V3_CREDENTIALS.${field} must be ${length} bytes`)
    return decoded
  }
  return { key: bytes("key", 256), keyId: bytes("keyId", 8) }
}

export function serializeCredential(credential: PermanentCredential): string {
  return JSON.stringify({ key: Buffer.from(credential.key).toString("base64"), keyId: Buffer.from(credential.keyId).toString("base64") })
}

/** Keeps Host, SNI and certificate identity on api.inline.chat while dialing the origin address. */
export function socketTarget(ip?: string) {
  if (ip === undefined) return { url: `wss://${HOST}/realtime/v3`, options: {} }
  const version = isIP(ip)
  if (!version) throw new Error("--ip must be an IPv4 or IPv6 address")
  return {
    url: `wss://${version === 6 ? `[${ip}]` : ip}/realtime/v3`,
    options: {
      headers: { Host: HOST },
      servername: HOST,
      rejectUnauthorized: true,
      checkServerIdentity: (_host: string, certificate: Parameters<typeof checkServerIdentity>[1]) => checkServerIdentity(HOST, certificate),
    },
  }
}

type Sdk = typeof import("../../packages/sdk/src/realtime/v3-connection")
type SocketFactory = NonNullable<Parameters<Sdk["InlineProtocolV3Connection"]["connect"]>[0]["webSocketFactory"]>
type WsConstructor = new (url: string, options?: Record<string, unknown>) => ReturnType<SocketFactory>

async function sdk() {
  const connection = await import(new URL("v3-connection.ts", SDK).href) as Sdk
  const roots = await import(new URL("production-trust-roots.ts", SDK).href) as typeof import("../../packages/sdk/src/realtime/production-trust-roots")
  // The SDK expects a `ws` socket; resolve it where the SDK itself resolves it.
  const { WebSocket } = createRequire(new URL("v3-connection.ts", SDK))("ws") as { WebSocket: WsConstructor }
  return { Connection: connection.InlineProtocolV3Connection, keys: roots.INLINE_PROTOCOL_PRODUCTION_PUBLIC_KEYS, WebSocket }
}

const bounded = async <T>(work: Promise<T>, milliseconds: number, label: string): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([work, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error(label)), milliseconds)
    })])
  } finally { clearTimeout(timer) }
}

// Provider and protocol errors can carry key material in causes; report a fixed class.
const reason = (error: unknown) => {
  const code = typeof error === "object" && error !== null && "code" in error ? String((error as { code: unknown }).code) : ""
  return code && /^[a-z-]+$/.test(code) ? `Inline Protocol ${code}` : error instanceof Error && error.message.length < 120 ? error.message : "Inline Protocol failure"
}

export type V3Probe = { handshake(): Promise<void>; getMe(credential: PermanentCredential): Promise<bigint>; close(): Promise<void> }

export async function connect(ip: string | undefined, timeoutMs = 15_000): Promise<V3Probe> {
  const { Connection, keys, WebSocket } = await sdk()
  const { Method } = await import(PROTOCOL.href) as typeof import("../../packages/protocol/src/core")
  const target = socketTarget(ip)
  let connection: Awaited<ReturnType<typeof Connection.connect>> | undefined
  return {
    async handshake() {
      connection = await bounded(Connection.connect({
        url: target.url, rsaPublicKeys: keys, temporary: true, connectTimeoutMs: timeoutMs, requestTimeoutMs: timeoutMs,
        webSocketFactory: (url: string) => new WebSocket(url, target.options),
      }), timeoutMs * 2, "Inline Protocol handshake timed out")
      await bounded(connection.ping(), timeoutMs, "Inline Protocol ping timed out")
    },
    async getMe(credential) {
      if (!connection) throw new Error("handshake did not complete")
      await bounded(connection.bindTemporary({ ...credential, serverSalt: 0n, temporary: false }), timeoutMs, "Temporary key binding timed out")
      const result = await bounded(connection.callRpc({ method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } }), timeoutMs, "getMe timed out")
      const id = result.oneofKind === "getMe" ? result.getMe.user?.id : undefined
      if (typeof id !== "bigint" || id <= 0n) throw new Error("getMe returned no user identity")
      return id
    },
    async close() { await connection?.close().catch(() => {}) },
  }
}

export async function probeV3(options: { ip?: string; credential?: PermanentCredential; advisory?: boolean; open?: typeof connect }): Promise<SmokeCheck[]> {
  const checks: SmokeCheck[] = []
  const advisory = options.advisory ? { advisory: true } : {}
  let probe: V3Probe | undefined
  try {
    probe = await (options.open ?? connect)(options.ip)
    try {
      await probe.handshake()
      checks.push({ name: "v3 handshake and ping", ok: true, detail: "temporary key exchanged; encrypted ping answered" })
    } catch (error) {
      checks.push({ name: "v3 handshake and ping", ok: false, detail: reason(error), ...advisory })
      return checks
    }
    if (!options.credential) {
      checks.push({ name: "v3 getMe", ok: true, skipped: true, detail: "skipped: INLINE_SMOKE_V3_CREDENTIALS is not configured" })
      return checks
    }
    try {
      checks.push({ name: "v3 getMe", ok: true, detail: `authenticated as user ${await probe.getMe(options.credential)}` })
    } catch (error) {
      checks.push({ name: "v3 getMe", ok: false, detail: reason(error), ...advisory })
    }
    return checks
  } catch (error) {
    checks.push({ name: "v3 handshake and ping", ok: false, detail: reason(error), ...advisory })
    return checks
  } finally {
    await probe?.close()
  }
}

/** One-time operator helper: log a dedicated smoke user in over V3 and print its permanent credential. */
async function login(email: string) {
  const { Connection, keys, WebSocket } = await sdk()
  const connection = await Connection.connect({ url: socketTarget().url, rsaPublicKeys: keys,
    webSocketFactory: (url: string) => new WebSocket(url) })
  try {
    const begun = await connection.authBegin({ identifier: { oneofKind: "email", email },
      client: { clientType: "cli", deviceName: "Inline release smoke", clientVersion: "release-smoke" } })
    process.stderr.write(`Enter the code sent to ${email}: `)
    const code = (await new Promise<string>((resolve) => process.stdin.once("data", (data) => resolve(String(data))))).trim()
    const completed = await connection.authComplete({ challengeId: begun.challengeId, code })
    if (completed.state.oneofKind !== "authorized") throw new Error(`Login did not authorize (${completed.state.oneofKind ?? "unknown"})`)
    // Secret material: paste into the INLINE_SMOKE_V3_CREDENTIALS production secret, then discard.
    console.log(serializeCredential(connection.authorization))
  } finally {
    await connection.close().catch(() => {})
    process.stdin.pause()
  }
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { origin: { type: "string" }, ip: { type: "string" }, login: { type: "string" },
    "credentials-stdin": { type: "boolean" } } })
  if (values.login) {
    await login(values.login)
  } else {
    const origin = values.origin ?? "canonical"
    let checks: SmokeCheck[]
    try {
      const secret = values["credentials-stdin"] ? (await Bun.stdin.text()).trim() : process.env.INLINE_SMOKE_V3_CREDENTIALS
      checks = await probeV3({ ip: values.ip || undefined, credential: parseCredential(secret),
        advisory: process.env.INLINE_SMOKE_PROBES === "advisory" })
    } catch (error) {
      checks = [{ name: "v3 configuration", ok: false, detail: error instanceof Error ? error.message : "invalid configuration" }]
    }
    const lines = report(checks)
    console.log(lines.join("\n"))
    annotate(origin, checks)
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `#### V3 protocol: ${origin}\n\n${lines.join("\n")}\n\n`)
    if (failed(checks)) process.exitCode = 1
    // ws timers can outlive a closed probe; the report is complete.
    process.exit()
  }
}
