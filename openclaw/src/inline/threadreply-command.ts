import type {
  OpenClawPluginApi,
  OpenClawPluginCommandDefinition,
  PluginCommandContext,
} from "openclaw/plugin-sdk/channel-entry-contract"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { DEFAULT_ACCOUNT_ID, normalizeAccountId } from "../openclaw-compat.js"
import { normalizeInlineTarget } from "./normalize.js"
import {
  resolveInlineGroupReplyThreadMode,
  type InlineReplyThreadMode,
} from "./policy.js"

type InlineGroupConfig = {
  replyThreadMode?: InlineReplyThreadMode | undefined
  [key: string]: unknown
}

type InlineAccountConfig = {
  groups?: Record<string, InlineGroupConfig | undefined> | undefined
  replyThreadMode?: InlineReplyThreadMode | undefined
  [key: string]: unknown
}

type InlineChannelConfig = InlineAccountConfig & {
  accounts?: Record<string, InlineAccountConfig | undefined> | undefined
}

const MODE_LABELS: Record<InlineReplyThreadMode, string> = {
  auto: "auto",
  thread: "thread",
  main: "main",
}
const INLINE_THREADREPLY_NATIVE_NAME = "threadreply"

type InlineThreadReplyCommandConfigRuntime = Pick<
  OpenClawPluginApi["runtime"]["config"],
  "current" | "mutateConfigFile"
>

type InlineBuiltinCommandSpec = {
  name: string
  description: string
  acceptsArgs: boolean
}

export const INLINE_THREADREPLY_COMMAND_SPEC = {
  name: "threadreply",
  nativeNames: { inline: INLINE_THREADREPLY_NATIVE_NAME },
  description: "Set Inline reply-thread mode for this chat.",
  channels: ["inline"],
  acceptsArgs: true,
} satisfies Pick<
  OpenClawPluginCommandDefinition,
  "name" | "nativeNames" | "description" | "channels" | "acceptsArgs"
>

export function listInlineBuiltinCommandSpecs(): InlineBuiltinCommandSpec[] {
  return [
    {
      name: INLINE_THREADREPLY_COMMAND_SPEC.nativeNames.inline ?? INLINE_THREADREPLY_COMMAND_SPEC.name,
      description: INLINE_THREADREPLY_COMMAND_SPEC.description,
      acceptsArgs: INLINE_THREADREPLY_COMMAND_SPEC.acceptsArgs,
    },
  ]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function asInlineConfig(value: unknown): InlineChannelConfig | undefined {
  return isRecord(value) ? (value as InlineChannelConfig) : undefined
}

function normalizeMode(raw: unknown): InlineReplyThreadMode | null {
  if (typeof raw !== "string") return null
  const normalized = raw.trim().toLowerCase()
  if (normalized === "on" || normalized === "threads") return "thread"
  if (normalized === "off" || normalized === "parent" || normalized === "parentchat") return "main"
  if (normalized === "auto" || normalized === "thread" || normalized === "main") return normalized
  return null
}

function resolveInlineGroupId(ctx: PluginCommandContext): string | null {
  const raw = ctx.from?.trim() ?? ""
  if (!/(^|:)chat:/i.test(raw)) return null
  const normalized = normalizeInlineTarget(raw)
  return normalized && /^[0-9]+$/.test(normalized) ? normalized : null
}

function resolveInlineConfigForAccount(
  inline: InlineChannelConfig,
  accountId: string | undefined,
): InlineAccountConfig {
  const normalized = normalizeAccountId(accountId)
  const accounts = isRecord(inline.accounts)
    ? (inline.accounts as Record<string, InlineAccountConfig | undefined>)
    : undefined
  const accountKey = accounts
    ? Object.keys(accounts).find((key) => normalizeAccountId(key) === normalized)
    : undefined

  if (accountKey && accounts?.[accountKey]) {
    return accounts[accountKey] as InlineAccountConfig
  }
  if (normalized !== DEFAULT_ACCOUNT_ID) {
    return {}
  }
  return inline
}

function resolveCurrentMode(params: {
  cfg: OpenClawConfig
  accountId?: string | undefined
  groupId: string
}): InlineReplyThreadMode {
  const inline = asInlineConfig(params.cfg.channels?.inline) ?? {}
  const accountConfig = resolveInlineConfigForAccount(inline, params.accountId)
  return resolveInlineGroupReplyThreadMode({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
    groupId: params.groupId,
    defaultMode: normalizeMode(accountConfig.replyThreadMode) ?? "auto",
  })
}

function readExplicitMode(params: {
  cfg: OpenClawConfig
  accountId?: string | undefined
  groupId: string
}): InlineReplyThreadMode | null {
  const inline = asInlineConfig(params.cfg.channels?.inline)
  if (!inline) return null
  const accountConfig = resolveInlineConfigForAccount(inline, params.accountId)
  const group = accountConfig.groups?.[params.groupId]
  return normalizeMode(group?.replyThreadMode)
}

function ensureRecordField(
  parent: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const current = parent[key]
  if (isRecord(current)) return current
  const next: Record<string, unknown> = {}
  parent[key] = next
  return next
}

function resolveMutableInlineConfigForAccount(
  inline: InlineChannelConfig,
  accountId: string | undefined,
): InlineAccountConfig {
  const normalized = normalizeAccountId(accountId)
  if (normalized === DEFAULT_ACCOUNT_ID) {
    const accounts = isRecord(inline.accounts)
      ? (inline.accounts as Record<string, InlineAccountConfig | undefined>)
      : undefined
    const defaultKey = accounts
      ? Object.keys(accounts).find((key) => normalizeAccountId(key) === DEFAULT_ACCOUNT_ID)
      : undefined
    const defaultAccount = defaultKey ? accounts?.[defaultKey] : undefined
    return defaultAccount ?? inline
  }

  const accounts = ensureRecordField(inline as Record<string, unknown>, "accounts") as Record<
    string,
    InlineAccountConfig | undefined
  >
  const accountKey =
    Object.keys(accounts).find((key) => normalizeAccountId(key) === normalized) ?? normalized
  const account = asInlineConfig(accounts[accountKey]) ?? {}
  accounts[accountKey] = account
  return account
}

function setGroupMode(params: {
  draft: OpenClawConfig
  accountId?: string | undefined
  groupId: string
  mode: InlineReplyThreadMode | "inherit"
}): void {
  const root = params.draft as OpenClawConfig & { channels?: Record<string, unknown> }
  const channels = root.channels ?? {}
  root.channels = channels
  const inline = asInlineConfig(channels.inline) ?? {}
  channels.inline = inline
  const accountConfig = resolveMutableInlineConfigForAccount(inline, params.accountId)
  const groups = ensureRecordField(accountConfig as Record<string, unknown>, "groups") as Record<
    string,
    InlineGroupConfig | undefined
  >
  const group = isRecord(groups[params.groupId]) ? (groups[params.groupId] as InlineGroupConfig) : {}
  groups[params.groupId] = group

  if (params.mode === "inherit") {
    delete group.replyThreadMode
    return
  }

  group.replyThreadMode = params.mode
}

function buildStatusText(params: {
  cfg: OpenClawConfig
  accountId?: string | undefined
  groupId: string
}): string {
  const explicit = readExplicitMode(params)
  const current = resolveCurrentMode(params)
  return [
    `Thread reply mode for chat ${params.groupId}: ${MODE_LABELS[current]}.`,
    explicit
      ? `Explicit chat override: ${MODE_LABELS[explicit]}.`
      : "Explicit chat override: inherit.",
  ].join("\n")
}

function buildMenuText(params: {
  cfg: OpenClawConfig
  accountId?: string | undefined
  groupId: string
}): string {
  return [
    buildStatusText(params),
    "",
    "Choose where automatic replies for this group should go.",
  ].join("\n")
}

function buildModeButtons() {
  return {
    inline: {
      buttons: [
        [
          { text: "Thread", callback_data: "/threadreply thread" },
          { text: "Main", callback_data: "/threadreply main" },
          { text: "Auto", callback_data: "/threadreply auto" },
        ],
        [{ text: "Inherit Mode", callback_data: "/threadreply inherit" }],
      ],
    },
  }
}

function normalizeAction(args: string): InlineReplyThreadMode | "inherit" | "status" | "help" | null {
  const [first = ""] = args.split(/\s+/).filter(Boolean)
  const normalized = first.trim().toLowerCase()
  if (!normalized || normalized === "help" || normalized === "options") return "help"
  if (normalized === "status" || normalized === "show") return "status"
  if (normalized === "inherit" || normalized === "default" || normalized === "unset") return "inherit"
  return normalizeMode(normalized)
}

export async function handleInlineThreadReplyCommand(
  api: OpenClawPluginApi,
  ctx: PluginCommandContext,
) {
  return await handleInlineThreadReplyCommandWithConfigRuntime(api.runtime.config, ctx)
}

export async function handleInlineThreadReplyCommandWithConfigRuntime(
  configRuntime: InlineThreadReplyCommandConfigRuntime,
  ctx: PluginCommandContext,
) {
  if (!ctx.isAuthorizedSender) {
    return { text: "This command requires authorization." }
  }

  const groupId = resolveInlineGroupId(ctx)
  if (!groupId) {
    return { text: "/threadreply is only available in Inline group chats." }
  }

  const currentConfig = configRuntime.current() as OpenClawConfig
  const args = ctx.args?.trim() ?? ""
  const [first = ""] = args.split(/\s+/).filter(Boolean)
  if (["min", "minimum", "threshold", "limit"].includes(first.trim().toLowerCase())) {
    return {
      text: "Reply-thread minimums are no longer used because message IDs are not chat message counts. Use /threadreply auto, thread, or main.",
    }
  }

  const action = normalizeAction(args)
  if (action === "help") {
    return {
      text: buildMenuText({
        cfg: currentConfig,
        accountId: ctx.accountId,
        groupId,
      }),
      channelData: buildModeButtons(),
    }
  }
  if (action === "status") {
    return {
      text: buildStatusText({
        cfg: currentConfig,
        accountId: ctx.accountId,
        groupId,
      }),
    }
  }
  if (!action) {
    return {
      text: [
        "Usage: /threadreply thread|main|auto|inherit|status",
        "",
        "- thread: route every eligible parent-chat reply into a per-message Inline reply thread.",
        "- main: keep automatic replies in the parent chat.",
        "- auto: create a reply thread only when the user explicitly asks for one.",
        "- inherit: remove this chat override and use account/default config.",
      ].join("\n"),
    }
  }

  const committed = await configRuntime.mutateConfigFile({
    afterWrite: { mode: "auto" },
    mutate: (draft) => {
      setGroupMode({
        draft,
        accountId: ctx.accountId,
        groupId,
        mode: action,
      })
    },
  })
  const nextConfig = committed.nextConfig as OpenClawConfig
  return {
    text: buildStatusText({
      cfg: nextConfig,
      accountId: ctx.accountId,
      groupId,
    }),
  }
}

export function createInlineThreadReplyCommand(
  api: OpenClawPluginApi,
): OpenClawPluginCommandDefinition {
  return {
    ...INLINE_THREADREPLY_COMMAND_SPEC,
    handler: async (ctx) => await handleInlineThreadReplyCommand(api, ctx),
  }
}
