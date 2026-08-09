export type LogLevel = "error" | "warn" | "info" | "debug" | "trace"

const levelOrder: Record<LogLevel, number> = {
  error: 0,
  warn: 1,
  info: 2,
  debug: 3,
  trace: 4,
}

export type LogSink = {
  error: (...args: unknown[]) => void
  warn: (...args: unknown[]) => void
  info: (...args: unknown[]) => void
  debug: (...args: unknown[]) => void
  trace: (...args: unknown[]) => void
}

export type LogFields = Readonly<Record<string, unknown>>

export type SanitizedLogValue =
  | null
  | boolean
  | number
  | string
  | readonly SanitizedLogValue[]
  | { readonly [key: string]: SanitizedLogValue }

export type LogRecord = {
  readonly timestamp: number
  readonly sequence: number
  readonly level: LogLevel
  readonly scope: string
  readonly event: string
  readonly fields?: Readonly<Record<string, SanitizedLogValue>>
}

export type LogRecordSink = {
  write: (record: LogRecord) => void
}

export type LogOptions = {
  level?: LogLevel
  sink?: LogSink | false
  recordSinks?: readonly LogRecordSink[]
  fields?: LogFields
  now?: () => number
}

const defaultSink: LogSink = {
  error: (...args) => console.error(...args),
  warn: (...args) => console.warn(...args),
  info: (...args) => console.info(...args),
  debug: (...args) => console.debug(...args),
  trace: (...args) => console.debug(...args),
}

const REDACTED = "[redacted]"
const MAX_DEPTH = 6
const MAX_KEYS = 64
const MAX_ARRAY_ITEMS = 64
const MAX_STRING_LENGTH = 2_000

const sensitiveKeys = new Set([
  "authorization",
  "accountid",
  "accesskey",
  "actionid",
  "apikey",
  "body",
  "caption",
  "cdnurl",
  "chatid",
  "cookie",
  "credential",
  "credentials",
  "content",
  "displayname",
  "dialogid",
  "documentid",
  "draft",
  "email",
  "encryptionkey",
  "firstname",
  "fullname",
  "fileid",
  "filename",
  "headers",
  "id",
  "lastname",
  "localpath",
  "interactionid",
  "mediakey",
  "mediaid",
  "mediaurl",
  "message",
  "messagebody",
  "messageid",
  "messagetext",
  "name",
  "otp",
  "passcode",
  "password",
  "path",
  "payload",
  "peerid",
  "phone",
  "phonenumber",
  "privatekey",
  "recipientid",
  "randomid",
  "refreshtoken",
  "requestid",
  "reqmsgid",
  "search",
  "searchterm",
  "senderid",
  "secret",
  "session",
  "signature",
  "signingkey",
  "signedurl",
  "setcookie",
  "spaceid",
  "text",
  "title",
  "token",
  "transactionid",
  "url",
  "userid",
  "username",
])

const normalizeKey = (key: string) =>
  key.replaceAll(/[-_\s]/g, "").toLowerCase()

const isSensitiveKey = (key: string) => {
  const normalized = normalizeKey(key)
  return sensitiveKeys.has(normalized) ||
    normalized.endsWith("token") ||
    normalized.endsWith("password") ||
    normalized.endsWith("secret")
}

const redactString = (value: string) => {
  const redacted = value
    .replace(/\bBearer\s+[^\s,;]+/gi, "Bearer [redacted]")
    .replace(/\bBasic\s+[^\s,;]+/gi, "Basic [redacted]")
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
    .replace(/(?:https?|wss?|file):\/\/[^\s)]+/gi, "[redacted-url]")
    .replace(/(?:blob|data):[^\s)]+/gi, "[redacted-url]")
    .replace(/(?:\/Users|\/home|\/private|\/tmp|\/var|\/Volumes)\/[^\s):]+/g, "[redacted-path]")
    .replace(/(^|[\s(])\/(?:[^/\s:()]+\/)+[^/\s:()]+/gm, "$1[redacted-path]")
    .replace(/[A-Z]:\\[^\s)]+/gi, "[redacted-path]")
    .replace(/([?&](?:access_?token|auth|code|key|password|secret|token)=)[^\s&#]*/gi, "$1[redacted]")
  return redacted.length > MAX_STRING_LENGTH
    ? `${redacted.slice(0, MAX_STRING_LENGTH)}…`
    : redacted
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const sanitizeValue = (
  value: unknown,
  seen: WeakSet<object>,
  depth: number,
): SanitizedLogValue => {
  if (value === null) return null
  if (typeof value === "string") return redactString(value)
  if (typeof value === "boolean" || typeof value === "number") return value
  if (typeof value === "bigint") return `${value}n`
  if (typeof value === "undefined") return "[undefined]"
  if (typeof value === "function") return "[function]"
  if (typeof value === "symbol") return "[symbol]"
  if (depth >= MAX_DEPTH) return "[max-depth]"

  if (value instanceof Error) {
    return {
      name: redactString(value.name),
      message: redactString(value.message),
      ...(value.stack ? { stack: redactString(value.stack) } : {}),
      ...(value.cause === undefined
        ? {}
        : { cause: sanitizeValue(value.cause, seen, depth + 1) }),
    }
  }
  if (value instanceof Date) return value.toISOString()
  if (ArrayBuffer.isView(value)) {
    return `[${value.constructor.name} ${value.byteLength} bytes]`
  }
  if (value instanceof ArrayBuffer) return `[ArrayBuffer ${value.byteLength} bytes]`
  if (typeof value !== "object") return redactString(String(value))
  if (seen.has(value)) return "[circular]"

  seen.add(value)
  try {
    if (Array.isArray(value)) {
      const items = value
        .slice(0, MAX_ARRAY_ITEMS)
        .map((item) => sanitizeValue(item, seen, depth + 1))
      if (value.length > MAX_ARRAY_ITEMS) items.push(`[+${value.length - MAX_ARRAY_ITEMS} items]`)
      return items
    }

    const sanitized: Record<string, SanitizedLogValue> = {}
    const entries = Object.entries(value).slice(0, MAX_KEYS)
    for (const [key, item] of entries) {
      sanitized[key] = isSensitiveKey(key)
        ? REDACTED
        : sanitizeValue(item, seen, depth + 1)
    }
    if (Object.keys(value).length > MAX_KEYS) {
      sanitized._truncated = `[+${Object.keys(value).length - MAX_KEYS} fields]`
    }
    return sanitized
  } finally {
    seen.delete(value)
  }
}

const freezeLogValue = (value: SanitizedLogValue): SanitizedLogValue => {
  if (value === null || typeof value !== "object") return value
  if (Array.isArray(value)) {
    for (const item of value) freezeLogValue(item)
  } else {
    for (const item of Object.values(value)) freezeLogValue(item)
  }
  return Object.freeze(value)
}

export const sanitizeLogFields = (
  fields: LogFields,
): Readonly<Record<string, SanitizedLogValue>> => {
  try {
    const sanitized = sanitizeValue(fields, new WeakSet(), 0)
    const record = isRecord(sanitized)
      ? sanitized as Record<string, SanitizedLogValue>
      : { details: sanitized }
    freezeLogValue(record)
    return record
  } catch {
    return { serialization: "[unserializable]" }
  }
}

export class LogRingBuffer implements LogRecordSink {
  private readonly records: LogRecord[] = []
  private readonly recordBytes: number[] = []
  private totalBytes = 0
  private dropped = 0

  constructor(
    readonly limit = 1_000,
    readonly maxBytes = 512 * 1_024,
  ) {
    if (!Number.isSafeInteger(limit) || limit <= 0) {
      throw new RangeError("Log ring buffer limit must be a positive integer")
    }
    if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) {
      throw new RangeError("Log ring buffer byte limit must be a positive integer")
    }
  }

  write(record: LogRecord) {
    const bytes = JSON.stringify(record).length
    if (bytes > this.maxBytes) {
      this.dropped += 1
      return
    }
    this.records.push(record)
    this.recordBytes.push(bytes)
    this.totalBytes += bytes
    while (this.records.length > this.limit || this.totalBytes > this.maxBytes) {
      this.records.shift()
      this.totalBytes -= this.recordBytes.shift() ?? 0
      this.dropped += 1
    }
  }

  snapshot(): readonly LogRecord[] {
    return [...this.records]
  }

  clear() {
    this.records.length = 0
    this.recordBytes.length = 0
    this.totalBytes = 0
    this.dropped = 0
  }

  get droppedCount() {
    return this.dropped
  }

  get sizeBytes() {
    return this.totalBytes
  }
}

type LogState = {
  level: LogLevel
  consoleSink: LogSink | undefined
  recordSinks: Set<LogRecordSink>
  now: () => number
  sequence: number
}

export class Log {
  private scope: string
  private state: LogState
  private fields: LogFields
  private levelOverride: LogLevel | undefined

  constructor(
    scope: string,
    levelOrOptions: LogLevel | LogOptions | undefined = "info",
    legacySink?: LogSink,
  ) {
    const options: LogOptions = typeof levelOrOptions === "object"
      ? levelOrOptions
      : { level: levelOrOptions, sink: legacySink }
    this.scope = scope
    this.fields = options.fields ?? {}
    this.levelOverride = undefined
    this.state = {
      level: options.level ?? "info",
      consoleSink: options.sink === false ? undefined : options.sink ?? defaultSink,
      recordSinks: new Set(options.recordSinks ?? []),
      now: options.now ?? Date.now,
      sequence: 0,
    }
  }

  withLevel(level: LogLevel) {
    const child = this.child(this.scope, this.fields)
    child.levelOverride = level
    return child
  }

  withScope(scope: string) {
    return this.child(`${this.scope}.${scope}`, this.fields)
  }

  withFields(fields: LogFields) {
    return this.child(this.scope, { ...this.fields, ...fields })
  }

  setLevel(level: LogLevel) {
    this.state.level = level
  }

  getLevel() {
    return this.levelOverride ?? this.state.level
  }

  addRecordSink(sink: LogRecordSink) {
    this.state.recordSinks.add(sink)
    return () => {
      this.state.recordSinks.delete(sink)
    }
  }

  trace(...args: unknown[]) {
    this.log("trace", ...args)
  }

  debug(...args: unknown[]) {
    this.log("debug", ...args)
  }

  info(...args: unknown[]) {
    this.log("info", ...args)
  }

  warn(...args: unknown[]) {
    this.log("warn", ...args)
  }

  error(...args: unknown[]) {
    this.log("error", ...args)
  }

  private log(level: LogLevel, ...args: unknown[]) {
    try {
      this.write(level, args)
    } catch {
      // Hostile values and accessors must not turn diagnostics into a crash.
    }
  }

  private write(level: LogLevel, args: unknown[]) {
    if (levelOrder[level] > levelOrder[this.getLevel()]) return

    const [head, ...tail] = args
    const event = redactString(typeof head === "string" ? head : "log")
    const fields: LogFields = {
      ...this.fields,
      ...(typeof head === "string" ? {} : { value: head }),
      ...(tail.length === 1 && isRecord(tail[0]) && !(tail[0] instanceof Error)
        ? tail[0]
        : tail.length > 0
          ? { details: tail }
          : {}),
    }
    const safeFields = Object.keys(fields).length > 0
      ? sanitizeLogFields(fields)
      : undefined
    const record: LogRecord = Object.freeze({
      timestamp: this.safeNow(),
      sequence: this.state.sequence++,
      level,
      scope: this.scope,
      event,
      ...(safeFields ? { fields: safeFields } : {}),
    })

    for (const sink of this.state.recordSinks) {
      try {
        sink.write(record)
      } catch {
        // Logging must never become an application failure.
      }
    }

    const consoleSink = this.state.consoleSink
    if (!consoleSink) return
    try {
      consoleSink[level](`[${record.scope}] ${record.event}`, record.fields ?? {})
    } catch {
      // Logging must never become an application failure.
    }
  }

  private child(scope: string, fields: LogFields) {
    const child = Object.create(Log.prototype) as Log
    child.scope = scope
    child.state = this.state
    child.fields = fields
    child.levelOverride = this.levelOverride
    return child
  }

  private safeNow() {
    try {
      const timestamp = this.state.now()
      return Number.isFinite(timestamp) ? timestamp : Date.now()
    } catch {
      return Date.now()
    }
  }
}
