import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { describeAccountSnapshot } from "openclaw/plugin-sdk/account-helpers"
import {
  deleteAccountFromConfigSection,
  setAccountEnabledInConfigSection,
} from "openclaw/plugin-sdk/core"
import { InlineConfigSchema } from "./config-schema.js"
import {
  findInlineTokenOwnerAccountId,
  formatDuplicateInlineTokenReason,
  listInlineAccountIds,
  resolveDefaultInlineAccountId,
  inspectInlineAccount,
  resolveInlineAccount,
  type ResolvedInlineAccount,
} from "./accounts.js"
import { buildChannelConfigSchema } from "../openclaw-compat.js"
import { hasInlineConfiguredState } from "../configured-state.js"

export const INLINE_CHANNEL = "inline" as const

export const inlineMeta = {
  id: INLINE_CHANNEL,
  label: "Inline",
  selectionLabel: "Inline (Bot API)",
  detailLabel: "Inline Bot",
  docsPath: "/channels/inline",
  docsLabel: "inline",
  blurb: "Use OpenClaw from Inline DMs and chats with an Inline bot token.",
  systemImage: "bubble.left.and.bubble.right",
  markdownCapable: true,
  aliases: ["inline-chat"],
  order: 30,
  quickstartAllowFrom: true,
}

export const inlineConfigSchema = buildChannelConfigSchema(InlineConfigSchema)

export function normalizeInlineAllowEntry(raw: string): string {
  const withoutChannel = raw.trim().replace(/^inline:/i, "").trim()
  if (/^chat:/i.test(withoutChannel)) {
    return withoutChannel
  }
  return withoutChannel.replace(/^user:/i, "").trim()
}

export function describeInlineAccount(account: ResolvedInlineAccount) {
  return {
    accountId: account.accountId,
    name: account.name,
    enabled: account.enabled,
    configured: account.configured,
    baseUrl: account.baseUrl ? "[set]" : "[missing]",
    tokenSource: account.tokenSource,
  }
}

export const inlineConfigAdapter = {
  listAccountIds: (cfg: OpenClawConfig) => listInlineAccountIds(cfg),
  resolveAccount: (cfg: OpenClawConfig, accountId?: string | null) =>
    resolveInlineAccount({ cfg, accountId: accountId ?? null }),
  inspectAccount: (cfg: OpenClawConfig, accountId?: string | null) =>
    inspectInlineAccount({ cfg, accountId: accountId ?? null }),
  defaultAccountId: (cfg: OpenClawConfig) => resolveDefaultInlineAccountId(cfg),
  setAccountEnabled: ({ cfg, accountId, enabled }: {
    cfg: OpenClawConfig
    accountId: string
    enabled: boolean
  }) =>
    setAccountEnabledInConfigSection({
      cfg,
      sectionKey: INLINE_CHANNEL,
      accountId,
      enabled,
      allowTopLevel: true,
    }),
  deleteAccount: ({ cfg, accountId }: { cfg: OpenClawConfig; accountId: string }) =>
    deleteAccountFromConfigSection({
      cfg,
      sectionKey: INLINE_CHANNEL,
      accountId,
      clearBaseFields: ["token", "tokenFile", "name", "enabled"],
    }),
  isConfigured: (account: ResolvedInlineAccount, cfg: OpenClawConfig) =>
    inspectInlineAccount({ cfg, accountId: account.accountId }).configured &&
    !findInlineTokenOwnerAccountId({ cfg, accountId: account.accountId }),
  unconfiguredReason: (account: ResolvedInlineAccount, cfg: OpenClawConfig) => {
    const inspected = inspectInlineAccount({ cfg, accountId: account.accountId })
    if (inspected.tokenStatus === "configured_unavailable") {
      return `not configured: token ${account.tokenSource} is configured but unavailable`
    }
    const ownerAccountId = findInlineTokenOwnerAccountId({ cfg, accountId: account.accountId })
    if (ownerAccountId) {
      return formatDuplicateInlineTokenReason({
        accountId: account.accountId,
        ownerAccountId,
      })
    }
    return "not configured"
  },
  describeAccount: (account: ResolvedInlineAccount, cfg: OpenClawConfig) => {
    const inspected = inspectInlineAccount({ cfg, accountId: account.accountId })
    const ownerAccountId = findInlineTokenOwnerAccountId({ cfg, accountId: account.accountId })
    return describeAccountSnapshot({
      account,
      configured: inspected.configured && !ownerAccountId,
      extra: {
        baseUrl: account.baseUrl ? "[set]" : "[missing]",
        tokenSource: inspected.tokenSource,
        reactionNotifications: account.reactionNotifications,
        ...(account.reactionAllowlist !== undefined
          ? { reactionAllowlist: account.reactionAllowlist }
          : {}),
      },
    })
  },
  resolveAllowFrom: ({ cfg, accountId }: { cfg: OpenClawConfig; accountId?: string | null }) =>
    (resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.allowFrom ?? []).map(
      (entry) => normalizeInlineAllowEntry(String(entry)),
    ),
  resolveDefaultTo: ({ cfg, accountId }: { cfg: OpenClawConfig; accountId?: string | null }) => {
    const raw = resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.defaultTo
    if (raw == null) return undefined
    const target = String(raw).trim()
    return target || undefined
  },
  formatAllowFrom: ({ allowFrom }: { allowFrom: Array<string | number> }) =>
    allowFrom
      .map((entry) => String(entry).trim())
      .filter(Boolean)
      .map((entry) => normalizeInlineAllowEntry(entry)),
  hasConfiguredState: hasInlineConfiguredState,
}
