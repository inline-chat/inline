import { z, type ZodTypeAny } from "zod"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"

const MB = 1024 * 1024
const VALID_ACCOUNT_ID_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/i
const INVALID_ACCOUNT_ID_CHARS_RE = /[^a-z0-9_-]+/g
const LEADING_DASH_RE = /^-+/g
const TRAILING_DASH_RE = /-+$/g
const BLOCKED_OBJECT_KEYS = new Set(["__proto__", "constructor", "prototype"])

export const DEFAULT_ACCOUNT_ID = "default"
export const PAIRING_APPROVED_MESSAGE =
  "\u2705 OpenClaw access approved. Send a message to start chatting."

type ZodSchemaWithToJsonSchema = ZodTypeAny & {
  toJSONSchema?: (params?: Record<string, unknown>) => unknown
}

export function normalizeAccountId(value?: string | null): string {
  const trimmed = (value ?? "").trim()
  if (!trimmed) return DEFAULT_ACCOUNT_ID

  const normalized = VALID_ACCOUNT_ID_RE.test(trimmed)
    ? trimmed.toLowerCase()
    : trimmed
        .toLowerCase()
        .replace(INVALID_ACCOUNT_ID_CHARS_RE, "-")
        .replace(LEADING_DASH_RE, "")
        .replace(TRAILING_DASH_RE, "")
        .slice(0, 64)

  if (!normalized || BLOCKED_OBJECT_KEYS.has(normalized)) {
    return DEFAULT_ACCOUNT_ID
  }

  return normalized
}

export function emptyPluginConfigSchema() {
  function error(message: string) {
    return { success: false as const, error: { issues: [{ path: [], message }] } }
  }

  return {
    safeParse(value: unknown) {
      if (value === undefined) {
        return { success: true as const, data: undefined }
      }
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        return error("expected config object")
      }
      if (Object.keys(value).length > 0) {
        return error("config must be empty")
      }
      return { success: true as const, data: value }
    },
    jsonSchema: {
      type: "object",
      additionalProperties: false,
      properties: {},
    },
  }
}

export function buildChannelConfigSchema(schema: ZodTypeAny) {
  const schemaWithJson = schema as ZodSchemaWithToJsonSchema
  if (typeof schemaWithJson.toJSONSchema === "function") {
    return {
      schema: schemaWithJson.toJSONSchema({
        target: "draft-07",
        unrepresentable: "any",
      }) as Record<string, unknown>,
    }
  }

  return {
    schema: {
      type: "object",
      additionalProperties: true,
    },
  }
}

export function formatPairingApproveHint(channelId: string): string {
  return `Approve via: openclaw pairing list ${channelId} / openclaw pairing approve ${channelId} <code>`
}

export const GroupPolicySchema = z.enum(["open", "disabled", "allowlist"])
export const DmPolicySchema = z.enum(["pairing", "allowlist", "open", "disabled"])
export const BlockStreamingCoalesceSchema = z
  .object({
    minChars: z.number().int().positive().optional(),
    maxChars: z.number().int().positive().optional(),
    idleMs: z.number().int().nonnegative().optional(),
  })
  .strict()

const ToolPolicyBaseSchema = z
  .object({
    allow: z.array(z.string()).optional(),
    alsoAllow: z.array(z.string()).optional(),
    deny: z.array(z.string()).optional(),
  })
  .strict()

export const ToolPolicySchema = ToolPolicyBaseSchema.superRefine((value, ctx) => {
  if (value.allow && value.allow.length > 0 && value.alsoAllow && value.alsoAllow.length > 0) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message:
        "tools policy cannot set both allow and alsoAllow in the same scope (merge alsoAllow into allow, or remove allow and use profile + alsoAllow)",
    })
  }
}).optional()

export function requireOpenAllowFrom(params: {
  policy?: string
  allowFrom?: Array<string | number>
  ctx: z.RefinementCtx
  path: Array<string | number>
  message: string
}) {
  if (params.policy !== "open") {
    return
  }
  const allow = (params.allowFrom ?? []).map((entry) => String(entry).trim()).filter(Boolean)
  if (allow.includes("*")) {
    return
  }
  params.ctx.addIssue({
    code: z.ZodIssueCode.custom,
    path: params.path,
    message: params.message,
  })
}

type CommandAuthorizer = {
  configured: boolean
  allowed: boolean
}

export function resolveControlCommandGate(params: {
  useAccessGroups: boolean
  authorizers: CommandAuthorizer[]
  allowTextCommands: boolean
  hasControlCommand: boolean
  modeWhenAccessGroupsOff?: "allow" | "deny" | "configured"
}): { commandAuthorized: boolean; shouldBlock: boolean } {
  const mode = params.modeWhenAccessGroupsOff ?? "allow"
  let commandAuthorized = false
  if (!params.useAccessGroups) {
    if (mode === "allow") {
      commandAuthorized = true
    } else if (mode === "deny") {
      commandAuthorized = false
    } else {
      const anyConfigured = params.authorizers.some((entry) => entry.configured)
      commandAuthorized = !anyConfigured || params.authorizers.some((entry) => entry.configured && entry.allowed)
    }
  } else {
    commandAuthorized = params.authorizers.some((entry) => entry.configured && entry.allowed)
  }
  return {
    commandAuthorized,
    shouldBlock: params.allowTextCommands && params.hasControlCommand && !commandAuthorized,
  }
}

export function resolveMentionGatingWithBypass(params: {
  isGroup: boolean
  requireMention: boolean
  canDetectMention: boolean
  wasMentioned: boolean
  implicitMention?: boolean
  hasAnyMention?: boolean
  allowTextCommands: boolean
  hasControlCommand: boolean
  commandAuthorized: boolean
}): { effectiveWasMentioned: boolean; shouldSkip: boolean; shouldBypassMention: boolean } {
  const shouldBypassMention =
    params.isGroup &&
    params.requireMention &&
    !params.wasMentioned &&
    !(params.hasAnyMention ?? false) &&
    params.allowTextCommands &&
    params.commandAuthorized &&
    params.hasControlCommand
  const effectiveWasMentioned =
    params.wasMentioned || params.implicitMention === true || shouldBypassMention
  return {
    effectiveWasMentioned,
    shouldSkip: params.requireMention && params.canDetectMention && !effectiveWasMentioned,
    shouldBypassMention,
  }
}

export function logInboundDrop(params: {
  log: (message: string) => void
  channel: string
  reason: string
  target?: string
}) {
  const target = params.target ? ` target=${params.target}` : ""
  params.log(`${params.channel}: drop ${params.reason}${target}`)
}

export function resolveChannelMediaMaxBytes(params: {
  cfg: OpenClawConfig
  resolveChannelLimitMb: (params: { cfg: OpenClawConfig; accountId: string }) => number | undefined
  accountId?: string | null
}): number | undefined {
  const accountId = normalizeAccountId(params.accountId)
  const channelLimit = params.resolveChannelLimitMb({
    cfg: params.cfg,
    accountId,
  })
  if (channelLimit) {
    return channelLimit * MB
  }
  if (params.cfg.agents?.defaults?.mediaMaxMb) {
    return params.cfg.agents.defaults.mediaMaxMb * MB
  }
  return undefined
}

export function createActionGate<T extends Record<string, boolean | undefined>>(actions: T | undefined) {
  return (key: keyof T, defaultValue = true): boolean => {
    const value = actions?.[key]
    if (value === undefined) {
      return defaultValue
    }
    return value !== false
  }
}

function toSnakeCaseKey(key: string): string {
  return key
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .toLowerCase()
}

function readSnakeCaseParamRaw(params: Record<string, unknown>, key: string): unknown {
  if (Object.hasOwn(params, key)) {
    return params[key]
  }
  const snakeKey = toSnakeCaseKey(key)
  if (snakeKey !== key && Object.hasOwn(params, snakeKey)) {
    return params[snakeKey]
  }
  return undefined
}

type StringParamOptions = {
  required?: boolean
  trim?: boolean
  label?: string
  allowEmpty?: boolean
}

export class ToolInputError extends Error {
  readonly status = 400

  constructor(message: string) {
    super(message)
    this.name = "ToolInputError"
  }
}

export function readStringParam(
  params: Record<string, unknown>,
  key: string,
  options: StringParamOptions & { required: true },
): string
export function readStringParam(
  params: Record<string, unknown>,
  key: string,
  options?: StringParamOptions,
): string | undefined
export function readStringParam(
  params: Record<string, unknown>,
  key: string,
  options: StringParamOptions = {},
): string | undefined {
  const { required = false, trim = true, label = key, allowEmpty = false } = options
  const raw = readSnakeCaseParamRaw(params, key)
  if (typeof raw !== "string") {
    if (required) {
      throw new ToolInputError(`${label} required`)
    }
    return undefined
  }
  const value = trim ? raw.trim() : raw
  if (!value && !allowEmpty) {
    if (required) {
      throw new ToolInputError(`${label} required`)
    }
    return undefined
  }
  return value
}

export function readNumberParam(
  params: Record<string, unknown>,
  key: string,
  options: { required?: boolean; label?: string; integer?: boolean; strict?: boolean } = {},
): number | undefined {
  const { required = false, label = key, integer = false, strict = false } = options
  const raw = readSnakeCaseParamRaw(params, key)
  let value: number | undefined
  if (typeof raw === "number" && Number.isFinite(raw)) {
    value = raw
  } else if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (trimmed) {
      const parsed = strict ? Number(trimmed) : Number.parseFloat(trimmed)
      if (Number.isFinite(parsed)) {
        value = parsed
      }
    }
  }
  if (value === undefined) {
    if (required) {
      throw new ToolInputError(`${label} required`)
    }
    return undefined
  }
  return integer ? Math.trunc(value) : value
}

export function readReactionParams(
  params: Record<string, unknown>,
  options: {
    emojiKey?: string
    removeKey?: string
    removeErrorMessage: string
  },
): { emoji: string; remove: boolean; isEmpty: boolean } {
  const emojiKey = options.emojiKey ?? "emoji"
  const removeKey = options.removeKey ?? "remove"
  const remove = typeof params[removeKey] === "boolean" ? params[removeKey] : false
  const emoji = readStringParam(params, emojiKey, {
    required: true,
    allowEmpty: true,
  })
  if (remove && !emoji) {
    throw new ToolInputError(options.removeErrorMessage)
  }
  return { emoji: emoji ?? "", remove, isEmpty: !emoji }
}

export function jsonResult(payload: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(payload, (_key, value) => (typeof value === "bigint" ? value.toString() : value), 2),
      },
    ],
    details: payload,
  }
}
