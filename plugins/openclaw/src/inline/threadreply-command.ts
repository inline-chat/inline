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
  replyThreadMode?: string | undefined
  [key: string]: unknown
}

type InlineAccountConfig = {
  groups?: Record<string, InlineGroupConfig | undefined> | undefined
  [key: string]: unknown
}

type InlineChannelConfig = InlineAccountConfig & {
  accounts?: Record<string, InlineAccountConfig | undefined> | undefined
}

const MODE_LABELS: Record<InlineReplyThreadMode, string> = {
  auto: "Auto",
  on: "On",
}
const INLINE_THREADREPLY_NATIVE_NAME = "threads"

export const INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE = {
  mode: "none",
  reason: "Inline reads the refreshed runtime config in-process.",
} as const

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
  name: "threads",
  nativeNames: { inline: INLINE_THREADREPLY_NATIVE_NAME },
  description: "Choose whether answers in this chat go in reply threads.",
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
  return normalized === "auto" || normalized === "on" ? normalized : null
}

// A command run inside a reply thread arrives with the parent chat as its `to`,
// so it applies to the chat the thread hangs off.
function resolveInlineChatId(ctx: PluginCommandContext): string | null {
  const normalized = normalizeInlineTarget(ctx.to?.trim() ?? "")
  return normalized && /^[0-9]+$/.test(normalized) ? normalized : null
}

export function resolveCurrentMode(params: {
  cfg: OpenClawConfig
  accountId?: string | undefined
  groupId: string
}): InlineReplyThreadMode {
  return resolveInlineGroupReplyThreadMode({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
    groupId: params.groupId,
  })
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

export function setGroupMode(params: {
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
  const current = resolveCurrentMode(params)
  return `Reply threads in this chat: ${MODE_LABELS[current]}.`
}

function buildMenuText(params: {
  cfg: OpenClawConfig
  accountId?: string | undefined
  groupId: string
}): string {
  return [
    buildStatusText(params),
    "",
    "Auto answers in the chat and starts a thread when someone asks. On answers each top-level message in a reply thread.",
  ].join("\n")
}

function buildModeButtons() {
  return {
    inline: {
      buttons: [
        [
          { text: "Auto", callback_data: "/threads auto" },
          { text: "On", callback_data: "/threads on" },
        ],
      ],
    },
  }
}

function normalizeAction(args: string): InlineReplyThreadMode | "inherit" | "status" | "help" | null {
  const [first = ""] = args.split(/\s+/).filter(Boolean)
  const normalized = first.trim().toLowerCase()
  if (!normalized || normalized === "help" || normalized === "options") return "help"
  if (normalized === "status" || normalized === "show") return "status"
  if (normalized === "reset") return "inherit"
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

  const groupId = resolveInlineChatId(ctx)
  if (!groupId) {
    return { text: "/threads is only available in Inline chats." }
  }

  const currentConfig = configRuntime.current() as OpenClawConfig
  const args = ctx.args?.trim() ?? ""
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
        "Usage: /threads auto|on|reset|status",
        "",
        "- auto: answer in the chat; start a thread when someone asks.",
        "- on: answer each top-level message in a reply thread.",
        "- reset: remove this chat's setting.",
      ].join("\n"),
    }
  }

  const committed = await configRuntime.mutateConfigFile({
    afterWrite: INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE,
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
