import { resolveNativeSkillsEnabled } from "openclaw/plugin-sdk/config-runtime"
import type { ChannelPlugin, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { parseAccessGroupAllowFromEntry } from "openclaw/plugin-sdk/security-runtime"
import { DEFAULT_ACCOUNT_ID, formatPairingApproveHint } from "../openclaw-compat.js"
import type { ResolvedInlineAccount } from "./accounts.js"
import {
  INLINE_DEFAULT_GROUP_POLICY,
  INLINE_DEFAULT_REQUIRE_MENTION,
} from "./config-schema.js"
import { normalizeInlineAllowEntry } from "./shared.js"

type InlineSecurityAdapter = NonNullable<ChannelPlugin<ResolvedInlineAccount>["security"]>
type InlineSecurityFinding = {
  checkId: string
  severity: "info" | "warn" | "critical"
  title: string
  detail: string
  remediation?: string
}

function hasEntries(value: unknown): boolean {
  return Array.isArray(value) && value.some((entry) => String(entry).trim())
}

function hasWildcard(value: unknown): boolean {
  return Array.isArray(value) && value.some((entry) => normalizeInlineAllowEntry(String(entry)) === "*")
}

function groupAllowFromEntries(groups: unknown): unknown[] {
  if (!groups || typeof groups !== "object" || Array.isArray(groups)) return []
  const entries: unknown[] = []
  for (const group of Object.values(groups)) {
    if (!group || typeof group !== "object" || Array.isArray(group)) continue
    const allowFrom = (group as { allowFrom?: unknown }).allowFrom
    if (Array.isArray(allowFrom)) {
      entries.push(...allowFrom)
    }
  }
  return entries
}

function hasGroupSenderEntries(account: ResolvedInlineAccount): boolean {
  return hasEntries(account.config.groupAllowFrom) || hasEntries(groupAllowFromEntries(account.config.groups))
}

function hasGroupSenderWildcard(account: ResolvedInlineAccount): boolean {
  return hasWildcard(account.config.groupAllowFrom) || hasWildcard(groupAllowFromEntries(account.config.groups))
}

function hasInlineCommandAllowFrom(cfg: OpenClawConfig): boolean {
  const allowFrom = cfg.commands?.allowFrom
  if (!allowFrom || typeof allowFrom !== "object") return false
  const byProvider = allowFrom as Record<string, unknown>
  return hasEntries(byProvider.inline) || hasEntries(byProvider["*"])
}

function groupDefaultRequiresMention(account: ResolvedInlineAccount): boolean {
  const groups = account.config.groups
  const wildcard = groups && typeof groups === "object" && !Array.isArray(groups)
    ? groups["*"]
    : undefined
  const wildcardRequireMention = wildcard && typeof wildcard === "object" && !Array.isArray(wildcard)
    ? (wildcard as { requireMention?: unknown }).requireMention
    : undefined
  if (typeof wildcardRequireMention === "boolean") return wildcardRequireMention
  return account.config.requireMention ?? INLINE_DEFAULT_REQUIRE_MENTION
}

function collectInvalidAllowFromEntries(params: {
  entries: unknown
  target: Set<string>
}): void {
  if (!Array.isArray(params.entries)) return
  for (const entry of params.entries) {
    if (parseAccessGroupAllowFromEntry(String(entry))) continue
    const normalized = normalizeInlineAllowEntry(String(entry))
    if (!normalized || normalized === "*") continue
    if (!/^[0-9]+$/.test(normalized)) {
      params.target.add(normalized)
    }
  }
}

function appendInvalidAllowFromFinding(
  findings: InlineSecurityFinding[],
  invalidEntries: Set<string>,
): void {
  if (invalidEntries.size === 0) return
  const examples = Array.from(invalidEntries).slice(0, 5)
  const more = invalidEntries.size > examples.length ? ` (+${invalidEntries.size - examples.length} more)` : ""
  findings.push({
    checkId: "channels.inline.allowFrom.invalid_entries",
    severity: "warn",
    title: "Inline allowlist contains non-numeric entries",
    detail: `Inline sender authorization requires numeric Inline user IDs or accessGroup entries. Found non-numeric allowlist entries: ${examples.join(", ")}${more}.`,
    remediation: "Replace names or chat ids with numeric Inline user IDs or accessGroup:<name> entries, then re-run the audit.",
  })
}

function appendInvalidReactionAllowlistFinding(
  findings: InlineSecurityFinding[],
  invalidEntries: Set<string>,
): void {
  if (invalidEntries.size === 0) return
  const examples = Array.from(invalidEntries).slice(0, 5)
  const more = invalidEntries.size > examples.length ? ` (+${invalidEntries.size - examples.length} more)` : ""
  findings.push({
    checkId: "channels.inline.reactionAllowlist.invalid_entries",
    severity: "warn",
    title: "Inline reaction sender allowlist contains non-numeric entries",
    detail: `Inline reaction sender authorization requires numeric Inline user IDs or accessGroup entries. Found non-numeric reactionAllowlist entries: ${examples.join(", ")}${more}.`,
    remediation: "Replace names or chat ids with numeric Inline user IDs or accessGroup:<name> entries, then re-run the audit.",
  })
}

export const inlineSecurityAdapter: InlineSecurityAdapter = {
  resolveDmPolicy: ({ cfg, accountId, account }) => {
    const resolvedAccountId = accountId ?? account.accountId ?? DEFAULT_ACCOUNT_ID
    const useAccountPath = Boolean(cfg.channels?.inline?.accounts?.[resolvedAccountId])
    const basePath = useAccountPath
      ? `channels.inline.accounts.${resolvedAccountId}.`
      : "channels.inline."
    return {
      policy: account.config.dmPolicy ?? "pairing",
      allowFrom: account.config.allowFrom ?? [],
      policyPath: `${basePath}dmPolicy`,
      allowFromPath: `${basePath}allowFrom`,
      approveHint: formatPairingApproveHint("inline"),
      normalizeEntry: (raw) => normalizeInlineAllowEntry(raw),
    }
  },
  collectWarnings: ({ account, cfg }) => {
    const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
    const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? INLINE_DEFAULT_GROUP_POLICY
    const groupRulesConfigured =
      Boolean(account.config.groups) && Object.keys(account.config.groups ?? {}).length > 0
    const groupSendersConfigured = hasGroupSenderEntries(account)
    if (groupPolicy === "allowlist" && !groupRulesConfigured && !groupSendersConfigured) {
      return [
        "- Inline groups: groupPolicy=\"allowlist\" but no groups or groupAllowFrom entries are configured, so all group messages will be dropped. Add channels.inline.groups entries or sender IDs under groupAllowFrom or groups.<chat>.allowFrom.",
      ]
    }
    if (groupPolicy !== "open") {
      return []
    }
    if (!groupDefaultRequiresMention(account)) {
      return [
        "- Inline groups: groupPolicy=\"open\" allows every group message to trigger replies because requireMention is disabled. Set channels.inline.requireMention=true or channels.inline.groups.\"*\".requireMention=true.",
      ]
    }
    return []
  },
  collectAuditFindings: ({ account, cfg }) => {
    const findings: InlineSecurityFinding[] = []
    const invalidEntries = new Set<string>()
    collectInvalidAllowFromEntries({
      entries: account.config.allowFrom,
      target: invalidEntries,
    })
    collectInvalidAllowFromEntries({
      entries: account.config.groupAllowFrom,
      target: invalidEntries,
    })
    collectInvalidAllowFromEntries({
      entries: groupAllowFromEntries(account.config.groups),
      target: invalidEntries,
    })
    appendInvalidAllowFromFinding(findings, invalidEntries)
    const invalidReactionAllowlistEntries = new Set<string>()
    collectInvalidAllowFromEntries({
      entries: account.config.reactionAllowlist,
      target: invalidReactionAllowlistEntries,
    })
    appendInvalidReactionAllowlistFinding(findings, invalidReactionAllowlistEntries)

    const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
    const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? INLINE_DEFAULT_GROUP_POLICY
    const groupsConfigured =
      Boolean(account.config.groups) && Object.keys(account.config.groups ?? {}).length > 0
    const groupSendersConfigured = hasGroupSenderEntries(account)
    const groupAccessEnabled =
      groupPolicy === "open" || (groupPolicy === "allowlist" && (groupsConfigured || groupSendersConfigured))
    if (!groupAccessEnabled) return findings

    if (cfg.commands?.useAccessGroups === false) {
      findings.push({
        checkId: "channels.inline.groups.commands.access_groups_disabled",
        severity: "critical",
        title: "Inline group command access groups are disabled",
        detail:
          "Inline group access is enabled while commands.useAccessGroups=false, so any sender in reachable Inline groups can run /... commands and control directives.",
        remediation:
          "Set commands.useAccessGroups=true and configure channels.inline.groupAllowFrom or groups.<chat>.allowFrom with explicit numeric Inline user IDs.",
      })
      return findings
    }

    if (hasGroupSenderWildcard(account)) {
      findings.push({
        checkId: "channels.inline.groups.allowFrom.wildcard",
        severity: "critical",
        title: "Inline group sender allowlist contains wildcard",
        detail:
          "Inline group sender allowlist contains \"*\", which allows any sender in reachable Inline groups to run /... commands and control directives.",
        remediation:
          "Remove \"*\" from channels.inline.groupAllowFrom and groups.<chat>.allowFrom, then use explicit numeric Inline user IDs.",
      })
      return findings
    }

    if (!groupSendersConfigured && !hasInlineCommandAllowFrom(cfg)) {
      const skillsParams: Parameters<typeof resolveNativeSkillsEnabled>[0] = {
        providerId: "inline" as Parameters<typeof resolveNativeSkillsEnabled>[0]["providerId"],
      }
      if (account.config.commands?.nativeSkills !== undefined) {
        skillsParams.providerSetting = account.config.commands.nativeSkills
      }
      if (cfg.commands?.nativeSkills !== undefined) {
        skillsParams.globalSetting = cfg.commands.nativeSkills
      }
      const skillsEnabled = resolveNativeSkillsEnabled(skillsParams)
      findings.push({
        checkId: "channels.inline.groups.allowFrom.missing",
        severity: "warn",
        title: "Inline group commands have no sender allowlist",
        detail:
          "Inline group access is enabled but no group sender allowlist is configured; group messages can still trigger replies, but /... commands and control buttons are rejected for every group member" +
          (skillsEnabled ? " (including skill commands)." : "."),
        remediation:
          "Set commands.allowFrom.inline, channels.inline.groupAllowFrom, or channels.inline.groups.<chat>.allowFrom with explicit numeric Inline user IDs.",
      })
    }
    return findings
  },
}
