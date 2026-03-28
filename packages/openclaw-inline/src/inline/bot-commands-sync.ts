import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { listInlineAccountIds, resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { callInlineBotApi, type InlineBotCommand } from "./bot-commands-api.js"
import { loadNativeCommandHelpersCompat, loadPluginCommandSpecsCompat } from "../sdk-runtime-compat.js"

const INLINE_BASE_NATIVE_COMMANDS: InlineBotCommand[] = [
  { command: "help", description: "Show available commands." },
  { command: "commands", description: "List all slash commands." },
  { command: "skill", description: "Run a skill by name." },
  { command: "status", description: "Show current status." },
  { command: "approve", description: "Approve or deny exec requests." },
  { command: "context", description: "Explain how context is built and used." },
  { command: "tts", description: "Control text-to-speech (TTS)." },
  { command: "whoami", description: "Show your sender id." },
  { command: "subagents", description: "List/stop/log/info subagent runs for this session." },
  { command: "usage", description: "Usage footer or cost summary." },
  { command: "stop", description: "Stop the current run." },
  { command: "restart", description: "Restart OpenClaw." },
  { command: "activation", description: "Set group activation mode." },
  { command: "send", description: "Set send policy." },
  { command: "reset", description: "Reset the current session." },
  { command: "new", description: "Start a new session." },
  { command: "compact", description: "Compact the session context." },
  { command: "think", description: "Set thinking level." },
  { command: "verbose", description: "Toggle verbose mode." },
  { command: "reasoning", description: "Toggle reasoning visibility." },
  { command: "elevated", description: "Toggle elevated mode." },
  { command: "exec", description: "Set exec defaults for this session." },
  { command: "model", description: "Show or set the model." },
  { command: "models", description: "List model providers or provider models." },
  { command: "queue", description: "Adjust queue settings." },
]

type InlineCommandsSyncLogger = {
  info?: (message: string) => void
  warn?: (message: string) => void
}

const INLINE_COMMAND_NAME_RE = /^[a-z0-9_]{1,32}$/
const INLINE_COMMAND_LIMIT = 100

type LoadedNativeCommandHelpers = Awaited<ReturnType<typeof loadNativeCommandHelpersCompat>>
type LoadedPluginCommandSpecs = Awaited<ReturnType<typeof loadPluginCommandSpecsCompat>>

const FALLBACK_NATIVE_COMMAND_HELPERS: LoadedNativeCommandHelpers = {
  available: false,
  listNativeCommandSpecsForConfig: () => [],
  listSkillCommandsForAgents: () => [],
}

const FALLBACK_PLUGIN_COMMAND_SPECS: LoadedPluginCommandSpecs = {
  available: false,
  specs: [],
}

function normalizeDynamicCommandName(raw: string): string {
  const trimmed = raw.trim().toLowerCase()
  const withoutSlash = trimmed.startsWith("/") ? trimmed.slice(1) : trimmed
  return withoutSlash.trim()
}

function appendUniqueCommand(
  out: InlineBotCommand[],
  seen: Set<string>,
  command: string,
  description: string,
): void {
  const normalized = normalizeDynamicCommandName(command)
  if (!INLINE_COMMAND_NAME_RE.test(normalized) || seen.has(normalized)) return
  const trimmedDescription = description.trim()
  if (!trimmedDescription) return
  seen.add(normalized)
  out.push({ command: normalized, description: trimmedDescription })
}

export function shouldSyncInlineNativeCommands(cfg: OpenClawConfig): boolean {
  const inlineNativeSetting = (
    cfg.channels?.inline as { commands?: { native?: boolean | "auto"; nativeSkills?: boolean | "auto" } } | undefined
  )?.commands?.native
  const effective = inlineNativeSetting ?? cfg.commands?.native ?? "auto"
  return effective !== false
}

function shouldSyncInlineNativeSkills(cfg: OpenClawConfig): boolean {
  const inlineNativeSkillsSetting = (
    cfg.channels?.inline as { commands?: { native?: boolean | "auto"; nativeSkills?: boolean | "auto" } } | undefined
  )?.commands?.nativeSkills
  const effective = inlineNativeSkillsSetting ?? cfg.commands?.nativeSkills ?? "auto"
  return effective !== false
}

async function buildInlineNativeCommandsForConfig(params: {
  cfg: OpenClawConfig
  nativeHelpers: LoadedNativeCommandHelpers
  pluginSpecs: LoadedPluginCommandSpecs
}): Promise<InlineBotCommand[]> {
  const commands = [...INLINE_BASE_NATIVE_COMMANDS]
  if (params.cfg.commands?.config === true) {
    commands.push({ command: "config", description: "Show or set config values." })
  }
  if (params.cfg.commands?.debug === true) {
    commands.push({ command: "debug", description: "Set runtime debug overrides." })
  }

  const { listNativeCommandSpecsForConfig, listSkillCommandsForAgents } = params.nativeHelpers
  const skillCommands =
    shouldSyncInlineNativeSkills(params.cfg)
      ? listSkillCommandsForAgents({ cfg: params.cfg })
      : []
  const nativeSpecs = listNativeCommandSpecsForConfig(params.cfg, { skillCommands })
  const { specs: pluginSpecs } = params.pluginSpecs
  const seen = new Set<string>()

  const resolved: InlineBotCommand[] = []
  for (const base of commands) {
    appendUniqueCommand(resolved, seen, base.command, base.description)
  }

  for (const spec of nativeSpecs) {
    appendUniqueCommand(resolved, seen, spec.name, spec.description)
  }

  for (const spec of pluginSpecs) {
    appendUniqueCommand(resolved, seen, spec.name, spec.description)
  }

  return resolved
}

export async function syncInlineNativeCommands(params: {
  cfg: OpenClawConfig
  logger?: InlineCommandsSyncLogger
}): Promise<{ attempted: number; synced: number; failed: number }> {
  const accountIds = listInlineAccountIds(params.cfg)
  const nativeEnabled = shouldSyncInlineNativeCommands(params.cfg)
  const nativeHelpers = nativeEnabled
    ? await loadNativeCommandHelpersCompat()
    : FALLBACK_NATIVE_COMMAND_HELPERS
  const pluginSpecs = nativeEnabled
    ? await loadPluginCommandSpecsCompat("inline")
    : FALLBACK_PLUGIN_COMMAND_SPECS
  const usingSdkSource = nativeHelpers.available || pluginSpecs.available
  const allCommands = nativeEnabled
    ? await buildInlineNativeCommandsForConfig({
        cfg: params.cfg,
        nativeHelpers,
        pluginSpecs,
      })
    : []
  const commands = allCommands.slice(0, INLINE_COMMAND_LIMIT)
  if (allCommands.length > INLINE_COMMAND_LIMIT) {
    params.logger?.warn?.(
      `[inline] native command sync truncating ${allCommands.length} commands to ${INLINE_COMMAND_LIMIT}`,
    )
  }
  params.logger?.info?.(
    `[inline] native command source: ${usingSdkSource ? "plugin-sdk" : "fallback"}`,
  )

  let synced = 0
  let failed = 0

  for (const accountId of accountIds) {
    const account = resolveInlineAccount({ cfg: params.cfg, accountId })
    if (!account.enabled || !account.configured || !account.baseUrl) {
      continue
    }

    let token: string
    try {
      token = await resolveInlineToken(account)
    } catch (err) {
      failed += 1
      params.logger?.warn?.(
        `[inline] native command sync skipped for account "${account.accountId}": ${String(err)}`,
      )
      continue
    }

    try {
      await callInlineBotApi<Record<string, never>>({
        baseUrl: account.baseUrl,
        token,
        methodName: "deleteMyCommands",
        method: "POST",
      })
      await callInlineBotApi<Record<string, never>>({
        baseUrl: account.baseUrl,
        token,
        methodName: "setMyCommands",
        method: "POST",
        body: { commands },
      })
      synced += 1
      params.logger?.info?.(
        `[inline] native commands synced for account "${account.accountId}" (${commands.length} command${commands.length === 1 ? "" : "s"})`,
      )
    } catch (err) {
      failed += 1
      params.logger?.warn?.(
        `[inline] native command sync failed for account "${account.accountId}": ${String(err)}`,
      )
    }
  }

  return {
    attempted: accountIds.length,
    synced,
    failed,
  }
}
