import { DEFAULT_ACCOUNT_ID, type OpenClawConfig } from "openclaw/plugin-sdk"

type InlineToolPolicy = Record<string, unknown>

type InlineGroupConfig = {
  requireMention?: boolean
  tools?: InlineToolPolicy
  toolsBySender?: Record<string, InlineToolPolicy | undefined>
}

type InlineGroups = Record<string, InlineGroupConfig | undefined>

function normalizeAccountId(raw: string | null | undefined): string {
  const trimmed = (raw ?? DEFAULT_ACCOUNT_ID).trim()
  return (trimmed || DEFAULT_ACCOUNT_ID).toLowerCase()
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

function resolveGroupConfig(groups: InlineGroups | undefined, groupId: string | null | undefined): InlineGroupConfig | undefined {
  if (!groups) return undefined
  const normalizedGroupId = (groupId ?? "").trim()
  if (!normalizedGroupId) return undefined
  const direct = groups[normalizedGroupId]
  if (direct) return direct
  const lowered = normalizedGroupId.toLowerCase()
  const matchedKey = Object.keys(groups).find((key) => key !== "*" && key.toLowerCase() === lowered)
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
