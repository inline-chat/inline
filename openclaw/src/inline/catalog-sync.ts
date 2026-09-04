import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { syncInlineNativeCommands } from "./bot-commands-sync.js"
import { syncInlineAgentSkills } from "./bot-skills-sync.js"

type InlineCatalogSyncLogger = {
  info?: (message: string) => void
  warn?: (message: string) => void
}

export type InlineCatalogSyncReason = "gateway_start" | "skill_changed" | "manual"

export type InlineCatalogSyncStatus = {
  reason: InlineCatalogSyncReason
  completedAt: string
  commands: { attempted: number; synced: number; failed: number }
  skills: { attempted: number; synced: number; failed: number }
}

let syncTail: Promise<unknown> = Promise.resolve()
let lastStatus: InlineCatalogSyncStatus | undefined

async function performInlineCatalogSync(params: {
  cfg: OpenClawConfig
  logger?: InlineCatalogSyncLogger
  reason: InlineCatalogSyncReason
}): Promise<InlineCatalogSyncStatus> {
  const commands = await syncInlineNativeCommands({
    cfg: params.cfg,
    ...(params.logger ? { logger: params.logger } : {}),
  })
  const skills = await syncInlineAgentSkills({
    cfg: params.cfg,
    ...(params.logger ? { logger: params.logger } : {}),
  })
  const status = {
    reason: params.reason,
    completedAt: new Date().toISOString(),
    commands,
    skills,
  } satisfies InlineCatalogSyncStatus
  lastStatus = status
  return status
}

/**
 * Republish every Inline-owned catalog from one serialized owner. Every call
 * gets a pass, so a change arriving during a sync cannot be lost behind the
 * older in-flight filesystem scan.
 */
export function syncInlineCatalogs(params: {
  cfg: OpenClawConfig
  logger?: InlineCatalogSyncLogger
  reason: InlineCatalogSyncReason
}): Promise<InlineCatalogSyncStatus> {
  const run = syncTail.then(
    () => performInlineCatalogSync(params),
    () => performInlineCatalogSync(params),
  )
  syncTail = run
  return run
}

export function getLastInlineCatalogSyncStatus(): InlineCatalogSyncStatus | undefined {
  return lastStatus
}
