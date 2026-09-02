import { randomUUID } from "node:crypto"
import { readFile } from "node:fs/promises"

const TELEMETRY_TIMEOUT_MS = 2_000
const TELEMETRY_DEDUP_MS = 5 * 60_000
const MAX_ERROR_MESSAGE_LENGTH = 8_000
const MAX_STACK_FRAMES = 80
const SENSITIVE_ENV_NAME = /(?:token|secret|password|api[_-]?key|authorization)/i

type TelemetryFrame = {
  filename: string
  abs_path: string
  function: string
  lineno: number
  colno?: number
  in_app: boolean
}

type HermesTelemetryEvent = {
  event_id: string
  timestamp: string
  platform: "javascript"
  level: "error"
  logger: "inline.hermes.sidecar"
  release?: string
  exception: {
    values: Array<{
      type: string
      value: string
      mechanism: { type: "inline_plugin_boundary"; handled: boolean }
      stacktrace?: { frames: TelemetryFrame[] }
    }>
  }
  tags: Record<string, string>
  sdk: { name: "inline.plugin.telemetry"; version: "1" }
}

const lastReports = new Map<string, number>()
let releasePromise: Promise<string | undefined> | undefined

export const HERMES_TELEMETRY_EXIT_TIMEOUT_MS = TELEMETRY_TIMEOUT_MS + 250

function telemetryDisabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const disabled = (value: string | undefined) =>
    value != null && ["1", "true", "yes", "on"].includes(value.trim().toLowerCase())
  const optedOut = (value: string | undefined) =>
    value != null && ["0", "false", "off"].includes(value.trim().toLowerCase())
  return disabled(env.DO_NOT_TRACK) || optedOut(env.INLINE_PLUGIN_TELEMETRY)
}

function resolveDsn(env: NodeJS.ProcessEnv = process.env): string {
  if (telemetryDisabled(env)) return ""
  return env.INLINE_HERMES_SENTRY_DSN?.trim() ?? ""
}

function sensitiveValues(env: NodeJS.ProcessEnv = process.env): string[] {
  return Object.entries(env)
    .filter(([name, value]) => SENSITIVE_ENV_NAME.test(name) && (value?.length ?? 0) >= 8)
    .map(([, value]) => value!)
}

export function redactHermesTelemetryText(
  value: unknown,
  env: NodeJS.ProcessEnv = process.env,
): string {
  let text = String(value ?? "")
    .replace(/\b(Authorization\s*[:=]\s*)(?:Basic|Bearer)\s+\S+/gi, "$1[REDACTED]")
    .replace(/\b((?:Basic|Bearer)\s+)\S+/gi, "$1[REDACTED]")
    .replace(/(https?:\/\/)[^/\s:@]+:[^@\s/]+@/gi, "$1[REDACTED]@")
    .replace(
      /([?&](?:access_token|auth|authorization|key|password|secret|token)[^=\s&]*)=([^&\s]+)/gi,
      "$1=[REDACTED]",
    )
    .replace(
      /\b([A-Za-z0-9_-]*(?:token|secret|password|api[_-]?key|authorization)[A-Za-z0-9_-]*)\s*([=:])\s*\S+/gi,
      "$1$2[REDACTED]",
    )
  for (const secret of sensitiveValues(env)) {
    text = text.replaceAll(secret, "[REDACTED]")
  }
  return text.slice(0, MAX_ERROR_MESSAGE_LENGTH)
}

function safeTag(value: string): string {
  const normalized = value.trim().toLowerCase()
  return normalized.length > 0 && normalized.length <= 80 && /^[a-z0-9._-]+$/.test(normalized)
    ? normalized
    : "unknown"
}

function parseStack(error: Error, env: NodeJS.ProcessEnv): TelemetryFrame[] {
  const frames: TelemetryFrame[] = []
  for (const rawLine of (error.stack ?? "").split("\n").slice(1)) {
    const line = redactHermesTelemetryText(rawLine.trim(), env)
    const match = /^at\s+(?:(.*?)\s+\()?(.+?):(\d+):(\d+)\)?$/.exec(line)
    if (!match) continue
    const filename = match[2]!
    frames.push({
      filename,
      abs_path: filename,
      function: match[1] || "<anonymous>",
      lineno: Number(match[3]),
      colno: Number(match[4]),
      in_app:
        filename.includes("@inline-chat/hermes-agent-adapter") ||
        filename.includes("/hermes-agent/") ||
        filename.endsWith("/plugin/inline/sidecar/index.mjs"),
    })
    if (frames.length >= MAX_STACK_FRAMES) break
  }
  return frames.reverse()
}

export function buildHermesTelemetryEvent(
  operation: string,
  error: unknown,
  options: { handled?: boolean; env?: NodeJS.ProcessEnv } = {},
): HermesTelemetryEvent {
  const env = options.env ?? process.env
  const exception = error instanceof Error ? error : new Error(String(error ?? "Unknown error"))
  const frames = parseStack(exception, env)
  return {
    event_id: randomUUID().replaceAll("-", ""),
    timestamp: new Date().toISOString(),
    platform: "javascript",
    level: "error",
    logger: "inline.hermes.sidecar",
    exception: {
      values: [{
        type: redactHermesTelemetryText(exception.name || "Error", env),
        value: redactHermesTelemetryText(exception.message || String(error), env),
        mechanism: {
          type: "inline_plugin_boundary",
          handled: options.handled ?? true,
        },
        ...(frames.length > 0 ? { stacktrace: { frames } } : {}),
      }],
    },
    tags: {
      operation: safeTag(operation),
      component: "sidecar",
      runtime: "node",
      os: process.platform,
      arch: process.arch,
    },
    sdk: { name: "inline.plugin.telemetry", version: "1" },
  }
}

async function resolveRelease(): Promise<string | undefined> {
  releasePromise ??= (async () => {
    for (const candidate of [
      new URL("../../../package.json", import.meta.url),
      new URL("../../package.json", import.meta.url),
    ]) {
      try {
        const parsed = JSON.parse(await readFile(candidate, "utf8")) as { version?: unknown }
        if (typeof parsed.version === "string" && parsed.version.trim()) {
          return `inline-hermes-plugin@${parsed.version.trim()}`
        }
      } catch {
        continue
      }
    }
    return undefined
  })()
  return releasePromise
}

function parseSentryDsn(dsn: string): { endpoint: string; publicKey: string } | null {
  try {
    const parsed = new URL(dsn)
    if (!/^https?:$/.test(parsed.protocol) || !parsed.username) return null
    const parts = parsed.pathname.split("/").filter(Boolean)
    const projectId = parts.pop()
    if (!projectId || !/^\d+$/.test(projectId)) return null
    const prefix = parts.length > 0 ? `/${parts.join("/")}` : ""
    return {
      endpoint: `${parsed.origin}${prefix}/api/${projectId}/envelope/`,
      publicKey: parsed.username,
    }
  } catch {
    return null
  }
}

export async function sendHermesPluginError(
  operation: string,
  error: unknown,
  options: { handled?: boolean; env?: NodeJS.ProcessEnv } = {},
): Promise<boolean> {
  const env = options.env ?? process.env
  const dsn = resolveDsn(env)
  const target = parseSentryDsn(dsn)
  if (!target) return false
  const event = buildHermesTelemetryEvent(operation, error, options)
  const release = await resolveRelease()
  if (release) event.release = release
  const envelope = [
    JSON.stringify({ event_id: event.event_id, dsn, sent_at: event.timestamp }),
    JSON.stringify({ type: "event", content_type: "application/json" }),
    JSON.stringify(event),
  ].join("\n")
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), TELEMETRY_TIMEOUT_MS)
  timeout.unref?.()
  try {
    const response = await fetch(target.endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/x-sentry-envelope",
        "x-sentry-auth": `Sentry sentry_version=7, sentry_key=${target.publicKey}, sentry_client=inline.plugin.telemetry/1`,
      },
      body: envelope,
      signal: controller.signal,
    })
    return response.ok
  } catch {
    return false
  } finally {
    clearTimeout(timeout)
  }
}

export function reportHermesPluginError(
  operation: string,
  error: unknown,
  options: { handled?: boolean } = {},
): void {
  try {
    const exception = error instanceof Error ? error : new Error(String(error ?? "Unknown error"))
    const key = `${safeTag(operation)}\0${exception.name}\0${redactHermesTelemetryText(exception.message)}`
    const now = Date.now()
    if (now - (lastReports.get(key) ?? 0) < TELEMETRY_DEDUP_MS) return
    lastReports.set(key, now)
    void sendHermesPluginError(operation, exception, options).catch(() => {})
  } catch {
    // Observability must never alter sidecar behavior.
  }
}
