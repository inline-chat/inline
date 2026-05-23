import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { listNativeCommandSpecsForConfig } from "openclaw/plugin-sdk/native-command-registry"
import { getPluginCommandSpecs } from "openclaw/plugin-sdk/plugin-runtime"
import { resolveAgentRoute } from "openclaw/plugin-sdk/routing"
import { listSkillCommandsForAgents } from "openclaw/plugin-sdk/skill-commands-runtime"
import {
  findInlineTokenOwnerAccountId,
  formatDuplicateInlineTokenReason,
  listInlineAccountIds,
  resolveInlineAccount,
  resolveInlineToken,
  type ResolvedInlineAccount,
} from "./accounts.js"
import { callInlineBotApi, type InlineBotCommand } from "./bot-commands-api.js"
import { adaptInlineVisibleCopy } from "./message-formatting.js"

type InlineCommandsSyncLogger = {
  info?: (message: string) => void
  warn?: (message: string) => void
}

const INLINE_COMMAND_NAME_RE = /^[a-z0-9_]{1,32}$/
const INLINE_COMMAND_LIMIT = 100
const INLINE_COMMAND_DESCRIPTION_LIMIT = 256
const INLINE_NATIVE_COMMAND_PROVIDER = "inline"

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
  logger?: InlineCommandsSyncLogger,
): void {
  const normalized = normalizeDynamicCommandName(command)
  if (!INLINE_COMMAND_NAME_RE.test(normalized) || seen.has(normalized)) return
  const rawDescription = adaptInlineVisibleCopy(description).trim()
  const trimmedDescription =
    rawDescription.length > INLINE_COMMAND_DESCRIPTION_LIMIT
      ? rawDescription.slice(0, INLINE_COMMAND_DESCRIPTION_LIMIT).trimEnd()
      : rawDescription
  if (!trimmedDescription) return
  if (trimmedDescription.length !== rawDescription.length) {
    logger?.warn?.(
      `[inline] bot command sync truncated description for /${normalized} to ${INLINE_COMMAND_DESCRIPTION_LIMIT} characters`,
    )
  }
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

export function shouldSyncInlineNativeCommandsForAccount(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
}): boolean {
  const effective = params.account.config.commands?.native ?? params.cfg.commands?.native ?? "auto"
  return effective !== false
}

export function shouldSyncInlineNativeSkillsForAccount(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
}): boolean {
  const effective = params.account.config.commands?.nativeSkills ?? params.cfg.commands?.nativeSkills ?? "auto"
  return effective !== false
}

async function buildInlineNativeCommandsForConfig(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
  logger?: InlineCommandsSyncLogger
}): Promise<InlineBotCommand[]> {
  const route = shouldSyncInlineNativeSkillsForAccount({ cfg: params.cfg, account: params.account })
    ? resolveAgentRoute({
        cfg: params.cfg,
        channel: INLINE_NATIVE_COMMAND_PROVIDER,
        accountId: params.account.accountId,
      })
    : null
  const skillCommands =
    route
      ? listSkillCommandsForAgents({
          cfg: params.cfg,
          agentIds: [route.agentId],
        })
      : []
  const nativeSpecs = listNativeCommandSpecsForConfig(params.cfg, {
    skillCommands,
    provider: INLINE_NATIVE_COMMAND_PROVIDER,
  })
  const pluginSpecs = getPluginCommandSpecs("inline", { config: params.cfg })
  const seen = new Set<string>()

  const resolved: InlineBotCommand[] = []
  for (const spec of nativeSpecs) {
    appendUniqueCommand(resolved, seen, spec.name, spec.description, params.logger)
  }

  for (const spec of pluginSpecs) {
    appendUniqueCommand(resolved, seen, spec.name, spec.description, params.logger)
  }

  return resolved
}

export async function syncInlineNativeCommands(params: {
  cfg: OpenClawConfig
  logger?: InlineCommandsSyncLogger
}): Promise<{ attempted: number; synced: number; failed: number }> {
  const accountIds = listInlineAccountIds(params.cfg)
  if (!accountIds.length) {
    params.logger?.info?.("[inline] bot command sync disabled")
    return { attempted: 0, synced: 0, failed: 0 }
  }

  let attempted = 0
  let synced = 0
  let failed = 0

  for (const accountId of accountIds) {
    const account = resolveInlineAccount({ cfg: params.cfg, accountId })
    const nativeEnabled = shouldSyncInlineNativeCommandsForAccount({ cfg: params.cfg, account })
    attempted += 1
    if (!account.enabled || !account.configured || !account.baseUrl) {
      continue
    }
    const ownerAccountId = findInlineTokenOwnerAccountId({
      cfg: params.cfg,
      accountId: account.accountId,
    })
    if (ownerAccountId) {
      failed += 1
      params.logger?.warn?.(
        `[inline] bot command sync skipped for account "${account.accountId}": ${formatDuplicateInlineTokenReason({
          accountId: account.accountId,
          ownerAccountId,
        })}`,
      )
      continue
    }

    let token: string
    try {
      token = await resolveInlineToken(account)
    } catch (err) {
      failed += 1
      params.logger?.warn?.(
        `[inline] bot command sync skipped for account "${account.accountId}": ${String(err)}`,
      )
      continue
    }

    if (!nativeEnabled) {
      try {
        await callInlineBotApi<Record<string, never>>({
          baseUrl: account.baseUrl,
          token,
          methodName: "deleteMyCommands",
          method: "POST",
        })
        synced += 1
        params.logger?.info?.(`[inline] bot commands cleared for account "${account.accountId}"`)
      } catch (err) {
        failed += 1
        params.logger?.warn?.(
          `[inline] bot command clear failed for account "${account.accountId}": ${String(err)}`,
        )
      }
      continue
    }

    const allCommands = await buildInlineNativeCommandsForConfig({
      cfg: params.cfg,
      account,
      ...(params.logger ? { logger: params.logger } : {}),
    })
    const commands = allCommands.slice(0, INLINE_COMMAND_LIMIT)
    if (allCommands.length > INLINE_COMMAND_LIMIT) {
      params.logger?.warn?.(
        `[inline] bot command sync truncating ${allCommands.length} commands to ${INLINE_COMMAND_LIMIT}`,
      )
    }
    if (commands.length === 0) {
      params.logger?.warn?.(
        `[inline] bot command sync skipped for account "${account.accountId}": no valid commands resolved`,
      )
      continue
    }

    try {
      await callInlineBotApi<Record<string, never>>({
        baseUrl: account.baseUrl,
        token,
        methodName: "setMyCommands",
        method: "POST",
        body: { commands },
      })
      synced += 1
      params.logger?.info?.(
        `[inline] bot commands synced for account "${account.accountId}" (${commands.length} command${commands.length === 1 ? "" : "s"})`,
      )
    } catch (err) {
      failed += 1
      params.logger?.warn?.(
        `[inline] bot command sync failed for account "${account.accountId}": ${String(err)}`,
      )
    }
  }

  return {
    attempted,
    synced,
    failed,
  }
}
