import { randomUUID } from "node:crypto"
import { readFile } from "node:fs/promises"

const OPENCLAW_SENTRY_DSN =
  "https://6db685760644bedf5ce289f031a14f73@o124360.ingest.us.sentry.io/4512015952576512"
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

type OpenClawTelemetryEvent = {
  event_id: string
  timestamp: string
  platform: "javascript"
  level: "error"
  logger: "inline.openclaw.plugin"
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

function telemetryDisabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const disabled = (value: string | undefined) =>
    value != null && ["1", "true", "yes", "on"].includes(value.trim().toLowerCase())
  const optedOut = (value: string | undefined) =>
    value != null && ["0", "false", "off"].includes(value.trim().toLowerCase())
  return disabled(env.DO_NOT_TRACK) || optedOut(env.INLINE_PLUGIN_TELEMETRY)
}

function resolveDsn(env: NodeJS.ProcessEnv = process.env): string {
  if (telemetryDisabled(env)) return ""
  if (env.INLINE_OPENCLAW_SENTRY_DSN !== undefined) {
    return env.INLINE_OPENCLAW_SENTRY_DSN.trim()
  }
  // Unit tests must never emit to Inline's production project. A local test
  // collector can still opt in through INLINE_OPENCLAW_SENTRY_DSN.
  if (env.NODE_ENV === "test" || env.VITEST === "true") return ""
  return OPENCLAW_SENTRY_DSN
}

function sensitiveValues(env: NodeJS.ProcessEnv = process.env): string[] {
  return Object.entries(env)
    .filter(([name, value]) => SENSITIVE_ENV_NAME.test(name) && (value?.length ?? 0) >= 8)
    .map(([, value]) => value!)
}

export function redactOpenClawTelemetryText(
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
  const stack = error.stack ?? ""
  const frames: TelemetryFrame[] = []
  for (const rawLine of stack.split("\n").slice(1)) {
    const line = redactOpenClawTelemetryText(rawLine.trim(), env)
    const match = /^at\s+(?:(.*?)\s+\()?(.+?):(\d+):(\d+)\)?$/.exec(line)
    if (!match) continue
    const filename = match[2]!
    const frame: TelemetryFrame = {
      filename,
      abs_path: filename,
      function: match[1] || "<anonymous>",
      lineno: Number(match[3]),
      colno: Number(match[4]),
      in_app:
        filename.includes("@inline-openclaw/inline") ||
        filename.includes("/openclaw/") ||
        /\/(?:channel-plugin-api|runtime-register-api|index)\.js$/.test(filename),
    }
    frames.push(frame)
    if (frames.length >= MAX_STACK_FRAMES) break
  }
  // Sentry's event protocol expects oldest frames first.
  return frames.reverse()
}

export function buildOpenClawTelemetryEvent(
  operation: string,
  error: unknown,
  options: { handled?: boolean; env?: NodeJS.ProcessEnv } = {},
): OpenClawTelemetryEvent {
  const env = options.env ?? process.env
  const exception = error instanceof Error ? error : new Error(String(error ?? "Unknown error"))
  const frames = parseStack(exception, env)
  return {
    event_id: randomUUID().replaceAll("-", ""),
    timestamp: new Date().toISOString(),
    platform: "javascript",
    level: "error",
    logger: "inline.openclaw.plugin",
    exception: {
      values: [{
        type: redactOpenClawTelemetryText(exception.name || "Error", env),
        value: redactOpenClawTelemetryText(exception.message || String(error), env),
        mechanism: {
          type: "inline_plugin_boundary",
          handled: options.handled ?? true,
        },
        ...(frames.length > 0 ? { stacktrace: { frames } } : {}),
      }],
    },
    tags: {
      operation: safeTag(operation),
      runtime: "node",
      os: process.platform,
      arch: process.arch,
    },
    sdk: { name: "inline.plugin.telemetry", version: "1" },
  }
}

async function resolveRelease(): Promise<string | undefined> {
  releasePromise ??= (async () => {
    try {
      const parsed = JSON.parse(
        await readFile(new URL("../package.json", import.meta.url), "utf8"),
      ) as { version?: unknown }
      if (typeof parsed.version === "string" && parsed.version.trim()) {
        return `inline-openclaw-plugin@${parsed.version.trim()}`
      }
    } catch {
      // Release metadata is helpful but must never interfere with reporting.
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

export async function sendOpenClawPluginError(
  operation: string,
  error: unknown,
  options: { handled?: boolean; env?: NodeJS.ProcessEnv } = {},
): Promise<boolean> {
  const env = options.env ?? process.env
  const dsn = resolveDsn(env)
  const target = parseSentryDsn(dsn)
  if (!target) return false

  const event = buildOpenClawTelemetryEvent(operation, error, options)
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

export function reportOpenClawPluginError(
  operation: string,
  error: unknown,
  options: { handled?: boolean } = {},
): void {
  try {
    const exception = error instanceof Error ? error : new Error(String(error ?? "Unknown error"))
    const key = `${safeTag(operation)}\0${exception.name}\0${redactOpenClawTelemetryText(exception.message)}`
    const now = Date.now()
    if (now - (lastReports.get(key) ?? 0) < TELEMETRY_DEDUP_MS) return
    lastReports.set(key, now)
    void sendOpenClawPluginError(operation, exception, options).catch(() => {})
  } catch {
    // Observability must never alter host plugin behavior.
  }
}

function wrapCallback<T extends (...args: never[]) => unknown>(operation: string, callback: T): T {
  return function (this: unknown, ...args: Parameters<T>): ReturnType<T> {
    try {
      const result = Reflect.apply(callback, this, args) as ReturnType<T>
      if (result && typeof (result as { then?: unknown }).then === "function") {
        return Promise.resolve(result).catch((error) => {
          reportOpenClawPluginError(operation, error)
          throw error
        }) as ReturnType<T>
      }
      return result
    } catch (error) {
      reportOpenClawPluginError(operation, error)
      throw error
    }
  } as T
}

function wrapSurface<T extends object>(prefix: string, surface: T): T {
  const wrapped = { ...surface } as Record<string, unknown>
  for (const [name, member] of Object.entries(wrapped)) {
    if (typeof member === "function") {
      wrapped[name] = wrapCallback(`${prefix}.${name}`, member as (...args: never[]) => unknown)
    }
  }
  return wrapped as T
}

function instrumentToolValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(instrumentToolValue)
  if (!value || typeof value !== "object") return value

  const tool = value as Record<string, unknown>
  const execute = tool.execute
  if (typeof execute !== "function") return value
  const name = typeof tool.name === "string" ? safeTag(tool.name) : "unknown"
  return new Proxy(tool, {
    get(target, property, receiver) {
      if (property === "execute") {
        return wrapCallback(`tool.${name}`, execute as (...args: never[]) => unknown)
      }
      return Reflect.get(target, property, receiver)
    },
  })
}

export function instrumentOpenClawPluginApi<T extends object>(value: T): T {
  const api = value as Record<string, unknown>
  return new Proxy(api, {
    get(target, property, receiver) {
      const member = Reflect.get(target, property, receiver)
      if (property === "registerTool" && typeof member === "function") {
        return (toolOrFactory: unknown, options?: unknown) => {
          const wrapped = typeof toolOrFactory === "function"
            ? wrapCallback("tool.factory", (...args: never[]) =>
                instrumentToolValue(Reflect.apply(toolOrFactory, undefined, args)))
            : instrumentToolValue(toolOrFactory)
          return Reflect.apply(member, target, [wrapped, options])
        }
      }
      if (property === "registerCommand" && typeof member === "function") {
        return (command: Record<string, unknown>) => {
          const handler = command.handler
          const name = typeof command.name === "string" ? safeTag(command.name) : "unknown"
          const wrapped = typeof handler === "function"
            ? { ...command, handler: wrapCallback(`command.${name}`, handler as (...args: never[]) => unknown) }
            : command
          return Reflect.apply(member, target, [wrapped])
        }
      }
      if (property === "on" && typeof member === "function") {
        return (event: string, handler: (...args: never[]) => unknown) =>
          Reflect.apply(member, target, [event, wrapCallback(`hook.${safeTag(event)}`, handler)])
      }
      return member
    },
  }) as T
}

export function instrumentOpenClawChannelPlugin<T extends object>(value: T): T {
  const plugin = { ...value } as Record<string, unknown>
  for (const name of [
    "lifecycle",
    "pairing",
    "outbound",
    "heartbeat",
    "directory",
    "resolver",
    "allowlist",
    "status",
    "gateway",
  ]) {
    const surface = plugin[name]
    if (surface && typeof surface === "object") {
      plugin[name] = wrapSurface(name, surface)
    }
  }
  const message = plugin.message
  if (message && typeof message === "object") {
    const wrappedMessage = { ...message } as Record<string, unknown>
    const send = wrappedMessage.send
    if (send && typeof send === "object") {
      wrappedMessage.send = wrapSurface("message.send", send)
    }
    plugin.message = wrappedMessage
  }
  return plugin as T
}

export function reportOpenClawRegistrationError(error: unknown): void {
  reportOpenClawPluginError("plugin.register", error, { handled: false })
}
