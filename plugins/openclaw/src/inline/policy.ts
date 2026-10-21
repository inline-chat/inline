import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { normalizeAccountId as normalizePluginAccountId } from "../openclaw-compat.js"
import type { InlineReplyThreadMode } from "./config-schema.js"
import { normalizeInlineTarget } from "./normalize.js"

type InlineToolPolicy = Record<string, unknown>

type InlineGroupConfig = {
  requireMention?: boolean | undefined
  replyThreadMode?: InlineReplyThreadMode | undefined
  replyThreadAutoCreateMinMessages?: number | undefined
  replyThreadRequireExplicitMention?: boolean | undefined
  replyThreadParentHistoryLimit?: number | undefined
  allowFrom?: Array<string | number> | undefined
  systemPrompt?: string | undefined
  tools?: InlineToolPolicy | undefined
  toolsBySender?: Record<string, InlineToolPolicy | undefined> | undefined
}

type InlineGroups = Record<string, InlineGroupConfig | undefined>
export type { InlineReplyThreadMode }

function normalizeAccountId(raw: string | null | undefined): string {
  return normalizePluginAccountId(raw)
}

function resolveInlineGroups(cfg: OpenClawConfig, accountId: string | null | undefined): InlineGroups | undefined {
  const inline = cfg.channels?.inline as
    | {
        groups?: InlineGroups
        accounts?: Record<string, { groups?: InlineGroups } | undefined>
      }
    | undefined
  if (!inline) return undefined

  const normalized = normalizeAccountId(accountId)
  const accounts = inline.accounts ?? {}
  const accountEntry =
    accounts[normalized] ??
    accounts[
      Object.keys(accounts).find((key) => key.toLowerCase() === normalized) ?? ""
    ]
  return accountEntry?.groups ?? inline.groups
}

function normalizeGroupId(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed || trimmed === "*") return trimmed
  const normalized = normalizeInlineTarget(trimmed)
  return normalized && /^[0-9]+$/.test(normalized) ? normalized : trimmed
}

function resolveGroupConfig(groups: InlineGroups | undefined, groupId: string | null | undefined): InlineGroupConfig | undefined {
  if (!groups) return undefined
  const normalizedGroupId = normalizeGroupId(groupId ?? "")
  if (!normalizedGroupId) return undefined
  const direct = groups[normalizedGroupId]
  if (direct) return direct
  const lowered = normalizedGroupId.toLowerCase()
  const matchedKey = Object.keys(groups).find((key) => key !== "*" && normalizeGroupId(key).toLowerCase() === lowered)
  return matchedKey ? groups[matchedKey] : undefined
}

/**
 * Normalizes a sender ID or `toolsBySender` key to the immutable numeric Inline
 * user ID it names (`42`, `user:42`, `inline:42`). Display names, usernames and
 * phone numbers can be changed or claimed by the sender, so they never select
 * a security policy and normalize to null.
 */
function normalizeSenderUserId(raw: string | null | undefined): string | null {
  const id = (raw ?? "").trim().replace(/^inline:/i, "").trim().replace(/^user:/i, "").trim()
  if (!/^[0-9]+$/.test(id)) return null
  const value = BigInt(id)
  return value > 0n ? value.toString() : null
}

/** A `toolsBySender` key that can never match a sender: not `*` and not a numeric Inline user ID. */
function isIgnoredSenderKey(rawKey: string): boolean {
  return rawKey.trim() !== "*" && normalizeSenderUserId(rawKey) === null
}

/** OpenClaw's own "no tools" shape. */
const denyAllTools = (): InlineToolPolicy => ({ allow: [], deny: ["*"] })

function resolveToolsBySender(params: {
  toolsBySender: Record<string, InlineToolPolicy | undefined> | undefined
  senderId: string | null | undefined
}): InlineToolPolicy | undefined {
  const entries = Object.entries(params.toolsBySender ?? {})
  if (!entries.length) return undefined
  // A name-keyed entry was meant for someone this policy cannot identify. Until
  // the owner re-keys it by user ID nobody in this scope gets tools: failing
  // open would hand the group default to the very sender the entry restricted.
  if (entries.some(([rawKey]) => isIgnoredSenderKey(rawKey))) return denyAllTools()

  const byUserId = new Map<string, InlineToolPolicy>()
  let wildcard: InlineToolPolicy | undefined
  for (const [rawKey, policy] of entries) {
    if (!policy) continue
    if (rawKey.trim() === "*") {
      wildcard = policy
      continue
    }
    const userId = normalizeSenderUserId(rawKey)
    if (userId && !byUserId.has(userId)) {
      byUserId.set(userId, policy)
    }
  }

  const senderUserId = normalizeSenderUserId(params.senderId)
  return (senderUserId ? byUserId.get(senderUserId) : undefined) ?? wildcard
}

/**
 * Lists `toolsBySender` keys that can never match because they are not numeric
 * Inline user IDs. Startup names them, and every scope that has one resolves to
 * no tools until it is re-keyed.
 */
export function listIgnoredInlineToolsBySenderKeys(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
}): string[] {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const ignored: string[] = []
  for (const [groupKey, groupConfig] of Object.entries(groups ?? {})) {
    for (const senderKey of Object.keys(groupConfig?.toolsBySender ?? {})) {
      if (!isIgnoredSenderKey(senderKey)) continue
      ignored.push(`groups.${JSON.stringify(groupKey)}.toolsBySender.${JSON.stringify(senderKey)}`)
    }
  }
  return ignored
}

export function resolveInlineGroupRequireMention(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  requireMentionDefault: boolean
}): boolean {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]
  if (typeof groupConfig?.requireMention === "boolean") return groupConfig.requireMention
  if (typeof defaultConfig?.requireMention === "boolean") return defaultConfig.requireMention
  return params.requireMentionDefault
}

export function resolveInlineGroupReplyThreadMode(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  defaultMode: InlineReplyThreadMode
}): InlineReplyThreadMode {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]
  return groupConfig?.replyThreadMode ?? defaultConfig?.replyThreadMode ?? params.defaultMode
}

export function resolveInlineGroupReplyThreadRequireExplicitMention(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  defaultRequireExplicitMention: boolean
}): boolean {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]
  if (typeof groupConfig?.replyThreadRequireExplicitMention === "boolean") {
    return groupConfig.replyThreadRequireExplicitMention
  }
  if (typeof defaultConfig?.replyThreadRequireExplicitMention === "boolean") {
    return defaultConfig.replyThreadRequireExplicitMention
  }
  return params.defaultRequireExplicitMention
}

export function resolveInlineGroupReplyThreadParentHistoryLimit(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  defaultLimit: number
}): number {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]
  return (
    groupConfig?.replyThreadParentHistoryLimit ??
    defaultConfig?.replyThreadParentHistoryLimit ??
    params.defaultLimit
  )
}

export function resolveInlineGroupSystemPrompt(params: {
  groups: InlineGroups | undefined
  groupId: string | null | undefined
}): string | undefined {
  return resolveGroupConfig(params.groups, params.groupId)?.systemPrompt?.trim() || undefined
}

export function resolveInlineGroupAccessPolicy(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  groupPolicy: "disabled" | "allowlist" | "open" | undefined
  hasGroupAllowFrom: boolean
}): {
  allowlistEnabled: boolean
  allowed: boolean
  groupConfig: InlineGroupConfig | undefined
  defaultConfig: InlineGroupConfig | undefined
} {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const hasGroups = Boolean(groups && Object.keys(groups).length > 0)
  const allowlistEnabled = params.groupPolicy === "allowlist" || hasGroups
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]
  const allowAll = allowlistEnabled && Boolean(groups && Object.hasOwn(groups, "*"))
  const senderFilterBypass = params.groupPolicy === "allowlist" && !hasGroups && params.hasGroupAllowFrom
  return {
    allowlistEnabled,
    allowed:
      params.groupPolicy === "disabled"
        ? false
        : !allowlistEnabled || allowAll || Boolean(groupConfig) || senderFilterBypass,
    groupConfig,
    defaultConfig,
  }
}

/**
 * Resolves the tool policy for a group turn. Sender-specific entries match the
 * immutable numeric sender ID only; the host's sender name, username and phone
 * are deliberately not accepted here.
 */
export function resolveInlineGroupToolPolicy(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  senderId: string | null | undefined
}): InlineToolPolicy | undefined {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]

  const groupSenderPolicy = resolveToolsBySender({
    toolsBySender: groupConfig?.toolsBySender,
    senderId: params.senderId,
  })
  if (groupSenderPolicy) return groupSenderPolicy
  if (groupConfig?.tools) return groupConfig.tools

  const defaultSenderPolicy = resolveToolsBySender({
    toolsBySender: defaultConfig?.toolsBySender,
    senderId: params.senderId,
  })
  if (defaultSenderPolicy) return defaultSenderPolicy
  return defaultConfig?.tools
}

export function resolveInlineGroupAllowFrom(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  accountAllowFrom: Array<string | number> | undefined
}): Array<string | number> | undefined {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]
  if (groupConfig?.allowFrom && groupConfig.allowFrom.length > 0) return groupConfig.allowFrom
  if (defaultConfig?.allowFrom && defaultConfig.allowFrom.length > 0) return defaultConfig.allowFrom
  return params.accountAllowFrom
}
