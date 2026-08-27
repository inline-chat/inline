export type Target = { chatId: bigint; userId?: never } | { userId: bigint; chatId?: never }
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json }
export type ErrorKind = "too_long" | "bad_format" | "forbidden" | "not_found" | "rate_limited" | "transient" | "unknown"
export type GenericInboundEvent = Record<string, unknown> & { kind?: string }
export type GenericSenderProfile = {
  id: string
  firstName?: string
  lastName?: string
  username?: string
  bot?: boolean
}
export type SecretRedaction = { value: string | null | undefined; label: string }

export const MAX_INLINE_ID = 9_223_372_036_854_775_807n

const sensitiveUrlParams = new Set([
  "access_token",
  "auth",
  "authorization",
  "key",
  "token",
])

export class SidecarError extends Error {
  readonly errorKind: ErrorKind

  constructor(message: string, errorKind: ErrorKind) {
    super(message)
    this.errorKind = errorKind
  }
}

export function parseTarget(record: Record<string, unknown>): Target {
  const targetRecord = asOptionalRecord(record.target) ?? record
  const chatId = readOptionalInlineId(targetRecord, "chatId")
  const userId = readOptionalInlineId(targetRecord, "userId")
  if (chatId && userId) throw new SidecarError("target cannot include both chatId and userId", "bad_format")
  if (chatId) return { chatId }
  if (userId) return { userId }
  throw new SidecarError("target requires chatId or userId", "bad_format")
}

export function normalizeUploadKind(raw: string | undefined, filePath: string): "photo" | "video" | "document" | "voice" {
  if (raw === "photo" || raw === "image") return "photo"
  if (raw === "video") return "video"
  if (raw === "voice") return "voice"
  if (raw === "document" || raw === "file") return "document"
  const lower = filePath.toLowerCase()
  if (/\.(png|jpg|jpeg|gif|webp|heic|heif)$/.test(lower)) return "photo"
  if (/\.(mp4|mov|webm)$/.test(lower)) return "video"
  return "document"
}

export function normalizeError(
  error: unknown,
  redact: (error: unknown) => string = defaultErrorText,
): { status: number; errorKind: ErrorKind; message: string } {
  if (error instanceof SidecarError) {
    return {
      status: statusForErrorKind(error.errorKind),
      errorKind: error.errorKind,
      message: redact(error),
    }
  }
  const message = redact(error)
  const lower = message.toLowerCase()
  if (lower.includes("rate") && lower.includes("limit")) {
    return { status: 429, errorKind: "rate_limited", message }
  }
  if (lower.includes("forbidden") || lower.includes("unauthorized")) {
    return { status: 403, errorKind: "forbidden", message }
  }
  if (lower.includes("not found") || lower.includes("missing")) {
    return { status: 404, errorKind: "not_found", message }
  }
  if (lower.includes("timeout") || lower.includes("network") || lower.includes("closed")) {
    return { status: 503, errorKind: "transient", message }
  }
  return { status: 500, errorKind: "unknown", message }
}

function statusForErrorKind(errorKind: ErrorKind): number {
  switch (errorKind) {
    case "bad_format":
      return 400
    case "forbidden":
      return 403
    case "not_found":
      return 404
    case "too_long":
      return 413
    case "rate_limited":
      return 429
    case "transient":
      return 503
    case "unknown":
      return 500
  }
}

export function normalizeInboundEvent(
  event: GenericInboundEvent,
  meId?: string | null,
  sender?: GenericSenderProfile,
  meUsername?: string | null,
): Json {
  if (event.kind === "message.new" || event.kind === "message.edit") {
    const message = asOptionalRecord(event.message)
    return safeJson({
      kind: event.kind,
      chatId: event.chatId,
      seq: event.seq,
      date: event.date,
      meId,
      meUsername,
      ...(sender ? { sender } : {}),
      message: message ? normalizeMessage(message) : null,
    })
  }

  if (event.kind === "message.action.invoke") {
    return safeJson({
      ...event,
      meId,
      meUsername,
      ...(sender ? { sender } : {}),
      dataBase64: event.data instanceof Uint8Array
        ? Buffer.from(event.data).toString("base64")
        : typeof event.data === "string"
          ? event.data
          : "",
    })
  }

  return safeJson({ ...event, meId, meUsername, ...(sender ? { sender } : {}) })
}

export function normalizeMessage(message: Record<string, unknown>): Record<string, unknown> {
  return {
    id: message.id,
    fromId: message.fromId,
    chatId: message.chatId,
    peerId: message.peerId,
    message: message.message ?? null,
    out: Boolean(message.out),
    date: message.date,
    mentioned: Boolean(message.mentioned),
    replyToMsgId: message.replyToMsgId ?? null,
    entities: message.entities ?? null,
    media: message.media ?? null,
    attachments: message.attachments ?? null,
    reactions: message.reactions ?? null,
    replies: message.replies ?? null,
    actions: message.actions ?? null,
    rev: message.rev ?? null,
    raw: message,
  }
}

export function redactText(value: unknown, secrets: SecretRedaction[]): string {
  let text = value instanceof Error ? value.message : String(value)
  for (const secret of secrets) {
    const raw = typeof secret.value === "string" ? secret.value : ""
    if (!raw) continue
    text = text.split(raw).join(secret.label)
  }
  return text
}

export function redactUrl(value: string): string {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    return value
  }

  if (url.username) url.username = "redacted"
  if (url.password) url.password = "redacted"
  const keys = Array.from(url.searchParams.keys())
  for (const key of keys) {
    const normalized = key.toLowerCase()
    if (sensitiveUrlParams.has(normalized) || normalized.includes("token")) {
      url.searchParams.set(key, "redacted")
    }
  }
  return url.toString()
}

export function safeJson(value: unknown): Json {
  if (value == null) return null
  if (typeof value === "string" || typeof value === "boolean") return value
  if (typeof value === "number") return Number.isFinite(value) ? value : null
  if (typeof value === "bigint") return value.toString()
  if (value instanceof Uint8Array) return Buffer.from(value).toString("base64")
  if (Array.isArray(value)) return value.map(safeJson)
  if (typeof value === "object") {
    const out: Record<string, Json> = {}
    for (const [key, item] of Object.entries(value)) {
      if (item !== undefined) out[key] = safeJson(item)
    }
    return out
  }
  return String(value)
}

export function asRecord(value: unknown): Record<string, unknown> {
  const record = asOptionalRecord(value)
  if (!record) throw new SidecarError("expected JSON object", "bad_format")
  return record
}

export function asOptionalRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

export function readRequiredString(record: Record<string, unknown>, key: string): string {
  const value = readOptionalString(record, key)
  if (!value) throw new SidecarError(`missing ${key}`, "bad_format")
  return value
}

export function readOptionalString(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key]
  if (typeof value === "string") return value.trim() || undefined
  if (typeof value === "bigint" || typeof value === "number") return String(value)
  return undefined
}

export function readOptionalBoolean(record: Record<string, unknown>, key: string): boolean | undefined {
  const value = record[key]
  if (typeof value === "boolean") return value
  if (typeof value === "string") {
    if (/^(1|true|yes|on)$/i.test(value)) return true
    if (/^(0|false|no|off)$/i.test(value)) return false
  }
  return undefined
}

export function readOptionalNumber(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key]
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value)
    if (Number.isFinite(parsed)) return parsed
  }
  return undefined
}

export function readRequiredInlineId(record: Record<string, unknown>, key: string): bigint {
  const value = readOptionalInlineId(record, key)
  if (value == null) throw new SidecarError(`missing ${key}`, "bad_format")
  return value
}

export function readOptionalInlineId(record: Record<string, unknown>, key: string): bigint | undefined {
  const value = record[key]
  if (value == null || value === "") return undefined
  return parseInlineId(value, key)
}

export function readInlineIdArray(
  record: Record<string, unknown>,
  key: string,
  maxItems: number,
  required = false,
): bigint[] {
  const value = record[key]
  if (value == null) {
    if (required) throw new SidecarError(`missing ${key}`, "bad_format")
    return []
  }
  if (!Array.isArray(value)) throw new SidecarError(`${key} must be an array`, "bad_format")
  if (value.length === 0 && required) throw new SidecarError(`${key} must not be empty`, "bad_format")
  if (value.length > maxItems) throw new SidecarError(`${key} supports at most ${maxItems} items`, "bad_format")

  const ids: bigint[] = []
  const seen = new Set<string>()
  for (let index = 0; index < value.length; index += 1) {
    const id = parseInlineId(value[index], `${key}[${index}]`)
    const normalized = id.toString()
    if (seen.has(normalized)) continue
    seen.add(normalized)
    ids.push(id)
  }
  return ids
}

export function parseOptionalInt(value: string | undefined): number | undefined {
  const raw = (value || "").trim()
  if (!raw || !/^\d+$/.test(raw)) return undefined
  const parsed = Number(raw)
  return Number.isSafeInteger(parsed) ? parsed : undefined
}

export function parseInlineId(value: unknown, field: string): bigint {
  try {
    if (typeof value === "number" && (!Number.isSafeInteger(value) || value <= 0)) {
      throw new Error("unsafe number")
    }
    const raw = typeof value === "string" ? value.trim() : value
    if (typeof raw === "string" && !/^[1-9][0-9]*$/.test(raw)) throw new Error("invalid digits")
    if (typeof raw !== "string" && typeof raw !== "bigint" && typeof raw !== "number") {
      throw new Error("invalid type")
    }
    const parsed = BigInt(raw)
    if (parsed <= 0n || parsed > MAX_INLINE_ID) throw new Error("out of range")
    return parsed
  } catch {
    throw new SidecarError(`${field} must be a positive signed 64-bit integer`, "bad_format")
  }
}

function defaultErrorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
