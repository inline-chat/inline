import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { normalizeAccountId as normalizePluginAccountId } from "../openclaw-compat.js"
import type { InlineReplyThreadMode } from "./config-schema.js"
import { normalizeInlineTarget } from "./normalize.js"

type InlineToolPolicy = Record<string, unknown>

type InlineGroupConfig = {
  requireMention?: boolean | undefined
  replyThreadMode?: InlineReplyThreadMode | undefined
  replyThreadAutoCreateMinMessages?: number | undefined
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

function normalizeSenderKey(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ""
  const withoutAt = trimmed.startsWith("@") ? trimmed.slice(1) : trimmed
  return withoutAt.toLowerCase()
}

function resolveToolsBySender(params: {
  toolsBySender: Record<string, InlineToolPolicy | undefined> | undefined
  senderId: string | null | undefined
  senderName: string | null | undefined
  senderUsername: string | null | undefined
  senderE164: string | null | undefined
}): InlineToolPolicy | undefined {
  const entries = Object.entries(params.toolsBySender ?? {})
  if (!entries.length) return undefined

  const normalizedMap = new Map<string, InlineToolPolicy>()
  let wildcard: InlineToolPolicy | undefined
  for (const [rawKey, policy] of entries) {
    if (!policy) continue
    const key = normalizeSenderKey(rawKey)
    if (!key) continue
    if (key === "*") {
      wildcard = policy
      continue
    }
    if (!normalizedMap.has(key)) {
      normalizedMap.set(key, policy)
    }
  }

  const candidates = [
    params.senderId,
    params.senderE164,
    params.senderUsername,
    params.senderName,
  ]
  for (const candidate of candidates) {
    const key = normalizeSenderKey(candidate ?? "")
    if (!key) continue
    const matched = normalizedMap.get(key)
    if (matched) return matched
  }
  return wildcard
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

export function resolveInlineGroupReplyThreadAutoCreateMinMessages(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  defaultMinMessages: number
}): number {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]
  return (
    groupConfig?.replyThreadAutoCreateMinMessages ??
    defaultConfig?.replyThreadAutoCreateMinMessages ??
    params.defaultMinMessages
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

export function resolveInlineGroupToolPolicy(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  groupId: string | null | undefined
  senderId: string | null | undefined
  senderName: string | null | undefined
  senderUsername: string | null | undefined
  senderE164: string | null | undefined
}): InlineToolPolicy | undefined {
  const groups = resolveInlineGroups(params.cfg, params.accountId)
  const groupConfig = resolveGroupConfig(groups, params.groupId)
  const defaultConfig = groups?.["*"]

  const groupSenderPolicy = resolveToolsBySender({
    toolsBySender: groupConfig?.toolsBySender,
    senderId: params.senderId,
    senderName: params.senderName,
    senderUsername: params.senderUsername,
    senderE164: params.senderE164,
  })
  if (groupSenderPolicy) return groupSenderPolicy
  if (groupConfig?.tools) return groupConfig.tools

  const defaultSenderPolicy = resolveToolsBySender({
    toolsBySender: defaultConfig?.toolsBySender,
    senderId: params.senderId,
    senderName: params.senderName,
    senderUsername: params.senderUsername,
    senderE164: params.senderE164,
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
