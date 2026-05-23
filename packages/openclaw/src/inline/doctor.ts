import type { ChannelPlugin } from "openclaw/plugin-sdk/core"

type DoctorAdapter = NonNullable<ChannelPlugin["doctor"]>
type DoctorAccount = Record<string, unknown>

function isRecord(value: unknown): value is DoctorAccount {
  return Boolean(value && typeof value === "object" && !Array.isArray(value))
}

function readInherited(
  account: DoctorAccount,
  parent: DoctorAccount | undefined,
  key: string,
): unknown {
  return account[key] !== undefined ? account[key] : parent?.[key]
}

function hasEntries(value: unknown): boolean {
  return Array.isArray(value) && value.some((entry) => String(entry).trim())
}

function hasConfiguredGroups(account: DoctorAccount, parent?: DoctorAccount): boolean {
  const groups = readInherited(account, parent, "groups")
  return isRecord(groups) && Object.keys(groups).length > 0
}

function hasGroupScopedSenders(groups: unknown): boolean {
  if (!isRecord(groups)) return false
  return Object.values(groups).some((group) => isRecord(group) && hasEntries(group.allowFrom))
}

function hasGroupSenders(account: DoctorAccount, parent?: DoctorAccount): boolean {
  return (
    hasEntries(readInherited(account, parent, "groupAllowFrom")) ||
    hasGroupScopedSenders(readInherited(account, parent, "groups"))
  )
}

function getGroupPolicy(account: DoctorAccount, parent?: DoctorAccount): string {
  return String(readInherited(account, parent, "groupPolicy") ?? "allowlist")
}

function collectInlineEmptyAllowlistWarnings(
  params: Parameters<NonNullable<DoctorAdapter["collectEmptyAllowlistExtraWarnings"]>>[0],
): string[] {
  if (params.channelName !== "inline") return []

  const account = params.account
  const parent = params.parent
  if (getGroupPolicy(account, parent) !== "allowlist") return []
  if (hasConfiguredGroups(account, parent) || hasGroupSenders(account, parent)) return []

  return [
    `- ${params.prefix}: Inline groupPolicy is "allowlist", but no group chats or group sender ids are configured. Group messages stay blocked until you add allowed chats under ${params.prefix}.groups, sender IDs under ${params.prefix}.groupAllowFrom or ${params.prefix}.groups.<chat>.allowFrom, or set ${params.prefix}.groupPolicy to "open" for broad group access.`,
  ]
}

export const inlineDoctor: DoctorAdapter = {
  dmAllowFromMode: "topOrNested",
  groupModel: "hybrid",
  groupAllowFromFallbackToAllowFrom: false,
  warnOnEmptyGroupSenderAllowlist: true,
  collectEmptyAllowlistExtraWarnings: collectInlineEmptyAllowlistWarnings,
  shouldSkipDefaultEmptyGroupAllowlistWarning: (params) => params.channelName === "inline",
}
