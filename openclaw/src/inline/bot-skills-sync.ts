import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { resolveAgentRoute } from "openclaw/plugin-sdk/routing"
import { listSkillCommandsForAgents } from "openclaw/plugin-sdk/skill-commands-runtime"
import {
  findInlineTokenOwnerAccountId,
  formatDuplicateInlineTokenReason,
  listInlineAccountIds,
  resolveInlineAccount,
  resolveInlineToken,
} from "./accounts.js"
import { callInlineBotApi } from "./bot-commands-api.js"
import { adaptInlineVisibleCopy } from "./message-formatting.js"

type InlineSkillsSyncLogger = {
  info?: (message: string) => void
  warn?: (message: string) => void
}

const INLINE_SKILL_LIMIT = 250
const INLINE_SKILL_NAME_LIMIT = 256
const INLINE_SKILL_DESCRIPTION_LIMIT = 4_000

export type InlinePublishedSkill = {
  key: string
  name: string
  description?: string
  sort_order: number
}

function truncateUtf16(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value
  const truncated = value.slice(0, maxLength)
  const lastCodeUnit = truncated.charCodeAt(truncated.length - 1)
  return lastCodeUnit >= 0xd800 && lastCodeUnit <= 0xdbff
    ? truncated.slice(0, -1)
    : truncated
}

export function buildInlinePublishedSkills(params: {
  cfg: OpenClawConfig
  accountId: string
}): InlinePublishedSkill[] {
  const route = resolveAgentRoute({
    cfg: params.cfg,
    channel: "inline",
    accountId: params.accountId,
  })
  const commands = listSkillCommandsForAgents({
    cfg: params.cfg,
    agentIds: [route.agentId],
  })
  const seen = new Set<string>()
  const skills: InlinePublishedSkill[] = []

  for (const command of commands) {
    if (skills.length >= INLINE_SKILL_LIMIT) break
    const key = command.skillName.trim()
    if (!key || key.length > INLINE_SKILL_NAME_LIMIT || seen.has(key)) continue
    const displayName = command.displayName?.trim() || key
    const name = truncateUtf16(displayName, INLINE_SKILL_NAME_LIMIT).trimEnd()
    if (!name) continue
    const description = truncateUtf16(
      adaptInlineVisibleCopy(command.description).trim(),
      INLINE_SKILL_DESCRIPTION_LIMIT,
    ).trimEnd()
    seen.add(key)
    skills.push({
      key,
      name,
      ...(description ? { description } : {}),
      sort_order: skills.length,
    })
  }
  return skills
}

export async function syncInlineAgentSkills(params: {
  cfg: OpenClawConfig
  logger?: InlineSkillsSyncLogger
}): Promise<{ attempted: number; synced: number; failed: number }> {
  const accountIds = listInlineAccountIds(params.cfg)
  let attempted = 0
  let synced = 0
  let failed = 0

  for (const accountId of accountIds) {
    const account = resolveInlineAccount({ cfg: params.cfg, accountId })
    attempted += 1
    if (!account.enabled || !account.configured || !account.baseUrl) continue

    const ownerAccountId = findInlineTokenOwnerAccountId({ cfg: params.cfg, accountId })
    if (ownerAccountId) {
      failed += 1
      params.logger?.warn?.(
        `[inline] bot skill sync skipped for account "${account.accountId}": ${formatDuplicateInlineTokenReason({ accountId: account.accountId, ownerAccountId })}`,
      )
      continue
    }

    try {
      const token = await resolveInlineToken(account)
      const skills = buildInlinePublishedSkills({ cfg: params.cfg, accountId: account.accountId })
      await callInlineBotApi<Record<string, never>>({
        baseUrl: account.baseUrl,
        token,
        methodName: "setMySkills",
        method: "POST",
        body: { skills },
      })
      synced += 1
      params.logger?.info?.(
        `[inline] bot skills synced for account "${account.accountId}" (${skills.length} skill${skills.length === 1 ? "" : "s"})`,
      )
    } catch (error) {
      failed += 1
      params.logger?.warn?.(
        `[inline] bot skill sync failed for account "${account.accountId}": ${String(error)}`,
      )
    }
  }

  return { attempted, synced, failed }
}
