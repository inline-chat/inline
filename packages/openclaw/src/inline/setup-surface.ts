import type { ChannelSetupWizard } from "openclaw/plugin-sdk/setup"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import {
  createAllowFromSection,
  createAccountScopedGroupAccessSection,
  createLegacyCompatChannelDmPolicy,
  createStandardChannelSetupStatus,
  DEFAULT_ACCOUNT_ID,
  formatCliCommand,
  patchChannelConfigForAccount,
  promptResolvedAllowFrom,
  setSetupChannelEnabled,
  splitSetupEntries,
} from "openclaw/plugin-sdk/setup"
import { inspectInlineAccount, listInlineAccountIds, resolveInlineAccount } from "./accounts.js"
import { INLINE_TOKEN_HELP_LINES, inlineSetupAdapter, resolveInlineSetupEnvToken } from "./setup-core.js"

const channel = "inline" as const

const INLINE_USER_ID_HELP_LINES = [
  "Allowlist Inline DMs by numeric user id.",
  "Accepted forms: 123456789, user:123456789, inline:123456789, inline:user:123456789.",
  "Ask the user to message the bot once, then use /whoami to see their Inline user id.",
  "Multiple entries: comma-separated.",
  "Docs: https://inline.chat/docs/openclaw",
]

const INLINE_GROUP_HELP_LINES = [
  "Allowlist Inline group chats by numeric chat id.",
  "Accepted forms: 123456789, chat:123456789, inline:123456789, *.",
  "Use * for every group chat; the setup keeps requireMention=true for broad group access.",
  "Use /whoami in a group and copy the Chat line to get the Inline chat id.",
  "Multiple entries: comma-separated.",
  "Docs: https://inline.chat/docs/openclaw",
]

type InlineGroupAccessPolicy = "allowlist" | "open" | "disabled"

type InlineGroupConfig = {
  requireMention?: boolean
  systemPrompt?: string
  tools?: unknown
  toolsBySender?: unknown
}

type InlineGroupAccessEntry = {
  input: string
  resolved: boolean
  id: string | null
  note?: string
}

function parseInlineAllowFromId(raw: string): string | null {
  const withoutChannel = raw.trim().replace(/^inline:/i, "").trim()
  if (/^chat:/i.test(withoutChannel)) return null
  const stripped = withoutChannel.replace(/^user:/i, "").trim()
  if (!/^[0-9]+$/.test(stripped)) return null
  try {
    return BigInt(stripped) > 0n ? stripped : null
  } catch {
    return null
  }
}

function parseInlineGroupId(raw: string): string | null {
  const stripped = raw.trim().replace(/^inline:/i, "").replace(/^chat:/i, "")
  if (stripped === "*") return stripped
  if (!/^[0-9]+$/.test(stripped)) return null
  try {
    return BigInt(stripped) > 0n ? stripped : null
  } catch {
    return null
  }
}

function resolveInlineGroupAccessEntries(entries: string[]): InlineGroupAccessEntry[] {
  return entries.map((entry) => {
    const id = parseInlineGroupId(entry)
    return {
      input: entry,
      resolved: Boolean(id),
      id,
      ...(id ? {} : { note: "Inline group id must be numeric, chat:<id>, inline:<id>, or *." }),
    }
  })
}

function normalizeInlineGroupAccessIds(entries: InlineGroupAccessEntry[]): string[] {
  const ids: string[] = []
  const seen = new Set<string>()
  for (const entry of entries) {
    const id = entry.id?.trim()
    if (!id || seen.has(id)) continue
    seen.add(id)
    ids.push(id)
  }
  return ids
}

function resolveInlineGroupPolicy(params: {
  cfg: OpenClawConfig
  accountId: string
}): InlineGroupAccessPolicy {
  const policy = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId }).config.groupPolicy
  return policy === "open" || policy === "disabled" ? policy : "allowlist"
}

function buildInlineGroupsAllowlist(params: {
  cfg: OpenClawConfig
  accountId: string
  entries: InlineGroupAccessEntry[]
}): Record<string, InlineGroupConfig> {
  const existing = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId }).config.groups ?? {}
  const groups: Record<string, InlineGroupConfig> = {}
  for (const id of normalizeInlineGroupAccessIds(params.entries)) {
    const current = existing[id] as InlineGroupConfig | undefined
    groups[id] = {
      ...current,
      requireMention: current?.requireMention ?? true,
    }
  }
  return groups
}

function ensureInlineDefaultGroupMentionGate(cfg: OpenClawConfig, accountId: string): OpenClawConfig {
  const resolved = resolveInlineAccount({ cfg, accountId })
  const wildcardGroup = resolved.config.groups?.["*"] as InlineGroupConfig | undefined
  if (wildcardGroup?.requireMention !== undefined) return cfg
  return patchChannelConfigForAccount({
    cfg,
    channel,
    accountId,
    patch: {
      groups: {
        ...resolved.config.groups,
        "*": {
          ...wildcardGroup,
          requireMention: true,
        },
      },
    },
  })
}

function formatInlineConfigBase(accountId: string): string {
  return accountId === DEFAULT_ACCOUNT_ID ? "channels.inline" : `channels.inline.accounts.${accountId}`
}

async function promptInlineAllowFromForAccount(params: {
  cfg: OpenClawConfig
  prompter: Parameters<NonNullable<ChannelSetupWizard["finalize"]>>[0]["prompter"]
  accountId?: string
}) {
  const accountId = params.accountId ?? DEFAULT_ACCOUNT_ID
  const resolved = resolveInlineAccount({ cfg: params.cfg, accountId })
  await params.prompter.note(INLINE_USER_ID_HELP_LINES.join("\n"), "Inline allowlist")
  const allowFrom = await promptResolvedAllowFrom({
    prompter: params.prompter,
    existing: resolved.config.allowFrom ?? [],
    message: "Inline allowFrom (user ids)",
    placeholder: "123456789, user:234567890",
    label: "Inline allowlist",
    parseInputs: splitSetupEntries,
    parseId: parseInlineAllowFromId,
    invalidWithoutTokenNote: "Inline token missing; use numeric user ids.",
    resolveEntries: async ({ entries }) =>
      entries.map((entry) => {
        const id = parseInlineAllowFromId(entry)
        return {
          input: entry,
          resolved: Boolean(id),
          id,
        }
      }),
  })
  return patchChannelConfigForAccount({
    cfg: params.cfg,
    channel,
    accountId,
    patch: {
      dmPolicy: "allowlist",
      allowFrom,
    },
  })
}

function shouldShowInlineDmAccessWarning(params: {
  cfg: OpenClawConfig
  accountId: string
}): boolean {
  const resolved = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId })
  const policy = resolved.config.dmPolicy ?? "pairing"
  const hasAllowFrom = (resolved.config.allowFrom ?? []).some((entry) => String(entry).trim())
  return policy === "pairing" && !hasAllowFrom
}

function buildInlineDmAccessWarningLines(accountId: string): string[] {
  const configBase = formatInlineConfigBase(accountId)
  return [
    "Your Inline bot is using DM policy: pairing.",
    "Any Inline user who discovers the bot can send pairing requests.",
    "For private use, configure an allowlist with your Inline user id:",
    `  ${formatCliCommand(`openclaw config set ${configBase}.dmPolicy "allowlist"`)}`,
    `  ${formatCliCommand(`openclaw config set ${configBase}.allowFrom '["YOUR_USER_ID"]'`)}`,
    "Docs: https://inline.chat/docs/openclaw",
  ]
}

function buildInlineGroupAccessWarningLines(params: {
  cfg: OpenClawConfig
  accountId: string
}): string[] {
  const resolved = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId })
  const configBase = formatInlineConfigBase(params.accountId)
  const policy = resolved.config.groupPolicy ?? "allowlist"
  const groups = resolved.config.groups ?? {}
  const hasGroups = Object.keys(groups).length > 0
  const hasGroupAllowFrom = (resolved.config.groupAllowFrom ?? []).some((entry) =>
    String(entry).trim(),
  )

  if (policy === "allowlist" && !hasGroups && !hasGroupAllowFrom) {
    return [
      "Inline groups are using groupPolicy: allowlist, but no group chats are configured.",
      "All Inline group messages will be dropped until you add groups or use the setup group access step.",
      `  ${formatCliCommand(`openclaw config set ${configBase}.groups '{"*":{"requireMention":true}}'`)}`,
      "Use a specific chat id instead of * when you only want selected groups.",
    ]
  }

  const wildcard = groups["*"] as InlineGroupConfig | undefined
  if (policy === "open" && wildcard?.requireMention !== true) {
    return [
      "Inline groups are open to every group chat without a default mention requirement.",
      "For safer broad group access, require bot mentions or switch to an explicit group allowlist:",
      `  ${formatCliCommand(`openclaw config set ${configBase}.groups '{"*":{"requireMention":true}}'`)}`,
      `  ${formatCliCommand(`openclaw config set ${configBase}.groupPolicy "allowlist"`)}`,
    ]
  }

  return []
}

const inlineDmPolicy = createLegacyCompatChannelDmPolicy({
  label: "Inline",
  channel,
  promptAllowFrom: promptInlineAllowFromForAccount,
})

export const inlineSetupWizard: ChannelSetupWizard = {
  channel,
  status: createStandardChannelSetupStatus({
    channelLabel: "Inline",
    configuredLabel: "configured",
    unconfiguredLabel: "needs bot token",
    configuredHint: "recommended · configured",
    unconfiguredHint: "recommended · bot token",
    configuredScore: 1,
    unconfiguredScore: 10,
    resolveConfigured: ({ cfg, accountId }) =>
      (accountId ? [accountId] : listInlineAccountIds(cfg)).some((resolvedAccountId) =>
        inspectInlineAccount({ cfg, accountId: resolvedAccountId }).configured,
      ),
  }),
  prepare: async ({ cfg, accountId, credentialValues }) => ({
    cfg: ensureInlineDefaultGroupMentionGate(cfg, accountId),
    credentialValues,
  }),
  credentials: [
    {
      inputKey: "token",
      providerHint: channel,
      credentialLabel: "Inline token",
      preferredEnvVar: "INLINE_TOKEN",
      helpTitle: "Inline token",
      helpLines: INLINE_TOKEN_HELP_LINES,
      envPrompt: "INLINE_TOKEN/INLINE_BOT_TOKEN detected. Use env var?",
      keepPrompt: "Inline token already configured. Keep it?",
      inputPrompt: "Enter Inline token",
      allowEnv: ({ accountId }) => accountId === DEFAULT_ACCOUNT_ID,
      inspect: ({ cfg, accountId }) => {
        const resolved = resolveInlineAccount({ cfg, accountId })
        const hasToken = typeof resolved.config.token === "string"
          ? Boolean(resolved.config.token.trim())
          : Boolean(resolved.config.token)
        const hasConfiguredValue = Boolean(
          hasToken || (resolved.config.tokenFile ?? "").trim(),
        )
        const resolvedValue = resolved.token?.trim()
        const envValue = accountId === DEFAULT_ACCOUNT_ID ? resolveInlineSetupEnvToken() : undefined
        return {
          accountConfigured: resolved.configured || hasConfiguredValue,
          hasConfiguredValue,
          ...(resolvedValue ? { resolvedValue } : {}),
          ...(envValue ? { envValue } : {}),
        }
      },
    },
  ],
  allowFrom: createAllowFromSection({
    helpTitle: "Inline allowlist",
    helpLines: INLINE_USER_ID_HELP_LINES,
    message: "Inline allowFrom (user ids)",
    placeholder: "123456789, user:234567890",
    invalidWithoutCredentialNote: "Inline token missing; use numeric user ids.",
    parseInputs: splitSetupEntries,
    parseId: parseInlineAllowFromId,
    resolveEntries: async ({ entries }) =>
      entries.map((entry) => {
        const id = parseInlineAllowFromId(entry)
        return {
          input: entry,
          resolved: Boolean(id),
          id,
        }
      }),
    apply: ({ cfg, accountId, allowFrom }) =>
      patchChannelConfigForAccount({
        cfg,
        channel,
        accountId,
        patch: {
          dmPolicy: "allowlist",
          allowFrom,
        },
      }),
  }),
  groupAccess: createAccountScopedGroupAccessSection<InlineGroupAccessEntry[]>({
    channel,
    label: "Inline group chats",
    placeholder: "123456789, chat:987654321, *",
    helpTitle: "Inline group access",
    helpLines: INLINE_GROUP_HELP_LINES,
    currentPolicy: ({ cfg, accountId }) => resolveInlineGroupPolicy({ cfg, accountId }),
    currentEntries: ({ cfg, accountId }) =>
      Object.keys(resolveInlineAccount({ cfg, accountId }).config.groups ?? {}),
    updatePrompt: ({ cfg, accountId }) =>
      Boolean(resolveInlineAccount({ cfg, accountId }).config.groups),
    resolveAllowlist: async ({ entries }) => resolveInlineGroupAccessEntries(entries),
    fallbackResolved: (entries) => resolveInlineGroupAccessEntries(entries),
    applyAllowlist: ({ cfg, accountId, resolved }) =>
      patchChannelConfigForAccount({
        cfg,
        channel,
        accountId,
        patch: {
          groupPolicy: "allowlist",
          groups: buildInlineGroupsAllowlist({ cfg, accountId, entries: resolved }),
        },
      }),
  }),
  finalize: async ({ cfg, accountId, prompter }) => {
    if (shouldShowInlineDmAccessWarning({ cfg, accountId })) {
      await prompter.note(
        buildInlineDmAccessWarningLines(accountId).join("\n"),
        "Inline DM access warning",
      )
    }
    const groupWarningLines = buildInlineGroupAccessWarningLines({ cfg, accountId })
    if (groupWarningLines.length > 0) {
      await prompter.note(groupWarningLines.join("\n"), "Inline group access warning")
    }
    return undefined
  },
  dmPolicy: inlineDmPolicy,
  disable: (cfg) => setSetupChannelEnabled(cfg, channel, false),
}

export { inlineSetupAdapter }
