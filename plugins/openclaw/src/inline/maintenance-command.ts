import type {
  OpenClawPluginApi,
  OpenClawPluginCommandDefinition,
  PluginCommandContext,
} from "openclaw/plugin-sdk/channel-entry-contract"
import { stat } from "node:fs/promises"
import {
  getLastInlineCatalogSyncStatus,
  syncInlineCatalogs,
  type InlineCatalogSyncStatus,
} from "./catalog-sync.js"
import {
  INLINE_SYNC_COMMAND_SPEC,
  INLINE_VERSION_COMMAND_SPEC,
} from "./maintenance-command-specs.js"

type InlineInstallRecord = {
  source?: string
  version?: string
  resolvedVersion?: string
  resolvedAt?: string
  installedAt?: string
}

type InlinePluginInspection = {
  plugin?: { version?: string }
  source?: { kind?: string }
}

type InlineInstallMetadata = {
  record: InlineInstallRecord | undefined
  timestampIsFilesystemMetadata: boolean
}

function formatTimestamp(value: string | undefined): string {
  if (!value) return "unavailable"
  const date = new Date(value)
  return Number.isNaN(date.valueOf()) ? "unavailable" : date.toISOString()
}

function summarizeSync(status: InlineCatalogSyncStatus | undefined): string {
  if (!status) return "not run in this process"
  const commands = `${status.commands.synced}/${status.commands.attempted} command account(s) synced`
  const skills = `${status.skills.synced}/${status.skills.attempted} skill account(s) synced`
  const failures = status.commands.failed + status.skills.failed
  return `${status.completedAt} (${status.reason}; ${commands}; ${skills}; ${failures} failure(s))`
}

function installRecord(api: OpenClawPluginApi): InlineInstallRecord | undefined {
  const plugins = (api.config as {
    plugins?: { installs?: Record<string, InlineInstallRecord> }
  }).plugins
  return plugins?.installs?.[api.id] ?? plugins?.installs?.inline
}

async function resolveInstallMetadata(api: OpenClawPluginApi): Promise<InlineInstallMetadata> {
  let record = installRecord(api)

  try {
    if (await api.runtime.gateway.isAvailable()) {
      const inspection = await api.runtime.gateway.request<InlinePluginInspection>("plugins.inspect", {
        pluginId: api.id,
      })
      record = {
        ...record,
        ...(inspection.plugin?.version ? { version: inspection.plugin.version } : {}),
        ...(inspection.source?.kind ? { source: inspection.source.kind } : {}),
      }
    }
  } catch {
    // Older hosts and restricted Gateway contexts may not expose plugin inspection.
  }

  if (record?.installedAt || !api.rootDir) {
    return { record, timestampIsFilesystemMetadata: false }
  }

  try {
    const metadata = await stat(api.rootDir)
    const timestampMs = Math.max(metadata.birthtimeMs, metadata.ctimeMs, metadata.mtimeMs)
    if (Number.isFinite(timestampMs) && timestampMs > 0) {
      record = { ...record, installedAt: new Date(timestampMs).toISOString() }
      return { record, timestampIsFilesystemMetadata: true }
    }
  } catch {
    // Version reporting remains useful when the install directory cannot be inspected.
  }

  return { record, timestampIsFilesystemMetadata: false }
}

export function buildInlineVersionText(
  api: OpenClawPluginApi,
  metadata: InlineInstallMetadata = {
    record: installRecord(api),
    timestampIsFilesystemMetadata: false,
  },
): string {
  const { record } = metadata
  const pluginVersion = api.version ?? record?.resolvedVersion ?? record?.version ?? "unknown"
  const resolvedVersion = record?.resolvedVersion
  const lines = [
    "Inline OpenClaw plugin",
    `Plugin version: ${pluginVersion}`,
    `OpenClaw version: ${api.runtime.version || "unknown"}`,
    `Install source: ${record?.source ?? "unavailable"}`,
    `Last install/update: ${formatTimestamp(record?.installedAt)}${metadata.timestampIsFilesystemMetadata ? " (filesystem metadata)" : ""}`,
  ]
  if (resolvedVersion && resolvedVersion !== pluginVersion) {
    lines.push(`Resolved version: ${resolvedVersion}`)
  }
  if (record?.resolvedAt) {
    lines.push(`Resolved at: ${formatTimestamp(record.resolvedAt)}`)
  }
  lines.push(`Last catalog sync: ${summarizeSync(getLastInlineCatalogSyncStatus())}`)
  return lines.join("\n")
}

export async function handleInlineSyncCommand(
  api: OpenClawPluginApi,
  ctx: PluginCommandContext,
): Promise<{ text: string }> {
  if (!ctx.isAuthorizedSender) {
    return { text: "This Inline command is not available to this sender." }
  }
  if (ctx.args?.trim()) {
    return { text: "Usage: /inline_sync" }
  }

  try {
    const status = await syncInlineCatalogs({
      cfg: api.config,
      logger: api.logger,
      reason: "manual",
    })
    const failed = status.commands.failed + status.skills.failed
    if (failed > 0) {
      return {
        text: `Inline catalog sync completed with ${failed} failure(s). Commands: ${status.commands.synced}/${status.commands.attempted} accounts. Skills: ${status.skills.synced}/${status.skills.attempted} accounts. Check OpenClaw logs for [inline] sync details.`,
      }
    }
    return {
      text: `Inline catalogs synced. Commands: ${status.commands.synced}/${status.commands.attempted} accounts. Skills: ${status.skills.synced}/${status.skills.attempted} accounts. Open or reopen the Skilled Agent editor in Inline to load the updated catalog.`,
    }
  } catch (error) {
    api.logger.warn?.(`[inline] manual catalog sync failed: ${String(error)}`)
    return { text: "Inline catalog sync failed. Check OpenClaw logs for [inline] sync details." }
  }
}

export function createInlineMaintenanceCommands(
  api: OpenClawPluginApi,
): OpenClawPluginCommandDefinition[] {
  return [
    {
      ...INLINE_SYNC_COMMAND_SPEC,
      handler: async (ctx) => await handleInlineSyncCommand(api, ctx),
    },
    {
      ...INLINE_VERSION_COMMAND_SPEC,
      handler: async (ctx) => {
        if (!ctx.isAuthorizedSender) {
          return { text: "This Inline command is not available to this sender." }
        }
        if (ctx.args?.trim()) {
          return { text: "Usage: /inline_version" }
        }
        return { text: buildInlineVersionText(api, await resolveInstallMetadata(api)) }
      },
    },
  ]
}
