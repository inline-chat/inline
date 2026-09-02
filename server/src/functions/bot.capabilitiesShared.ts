import { db } from "@in/server/db"
import { userNotDeleted, users, type DbBotCapability, type DbUser } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { BotCapability_Kind, type BotCapability } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import {
  AGENT_CONFIGURATION_CAPABILITY_KIND,
  AGENT_CONFIGURATION_VERSION,
  decodeAgentConfigurationCatalog,
  encodeAgentConfigurationCatalog,
  normalizeAgentConfigurationCatalog,
} from "@in/server/modules/agentConfiguration"

export const BOT_CAPABILITY_LIMIT = 100
export const BOT_CHAT_SETTINGS_VERSION = 1

const capabilityKindToStorage = (kind: BotCapability_Kind): string | undefined =>
  kind === BotCapability_Kind.CHAT_SETTINGS
    ? "chat_settings"
    : kind === BotCapability_Kind.AGENT_CONFIGURATION
      ? AGENT_CONFIGURATION_CAPABILITY_KIND
      : undefined

const capabilityKindFromStorage = (kind: string): BotCapability_Kind | undefined =>
  kind === "chat_settings"
    ? BotCapability_Kind.CHAT_SETTINGS
    : kind === AGENT_CONFIGURATION_CAPABILITY_KIND
      ? BotCapability_Kind.AGENT_CONFIGURATION
      : undefined

export async function getCurrentBotOrThrow(currentUserId: number): Promise<DbUser> {
  const [bot] = await db
    .select()
    .from(users)
    .where(and(eq(users.id, currentUserId), eq(users.bot, true), userNotDeleted()))
    .limit(1)
  if (!bot) throw RealtimeRpcError.BadRequest()
  return bot
}

export function normalizeBotCapabilities(
  capabilities: BotCapability[] | undefined,
): Array<{ kind: string; version: number; payload?: Uint8Array | null }> {
  if (!capabilities) return []
  if (capabilities.length > BOT_CAPABILITY_LIMIT) throw RealtimeRpcError.BadRequest()

  const seen = new Set<string>()
  return capabilities.map((capability) => {
    const kind = capabilityKindToStorage(capability.kind)
    const expectedVersion = kind === AGENT_CONFIGURATION_CAPABILITY_KIND
      ? AGENT_CONFIGURATION_VERSION
      : BOT_CHAT_SETTINGS_VERSION
    if (
      !kind ||
      seen.has(kind) ||
      !Number.isSafeInteger(capability.version) ||
      capability.version !== expectedVersion
    ) {
      throw RealtimeRpcError.BadRequest()
    }
    seen.add(kind)
    if (kind === AGENT_CONFIGURATION_CAPABILITY_KIND) {
      if (!capability.agentConfiguration) throw RealtimeRpcError.BadRequest()
      const catalog = normalizeAgentConfigurationCatalog(capability.agentConfiguration)
      return { kind, version: capability.version, payload: encodeAgentConfigurationCatalog(catalog) }
    }
    if (capability.agentConfiguration) throw RealtimeRpcError.BadRequest()
    return { kind, version: capability.version, payload: null }
  })
}

export function toProtocolBotCapability(
  capability: Pick<DbBotCapability, "kind" | "version" | "payload">,
  options: { includePayload?: boolean } = { includePayload: true },
): BotCapability | undefined {
  const kind = capabilityKindFromStorage(capability.kind)
  if (!kind) return undefined
  return {
    kind,
    version: capability.version,
    agentConfiguration: kind === BotCapability_Kind.AGENT_CONFIGURATION && options.includePayload !== false
      ? decodeAgentConfigurationCatalog(capability.payload)
      : undefined,
  }
}

export function hasChatSettingsCapability(
  capabilities: ReadonlyArray<Pick<DbBotCapability, "kind" | "version">>,
): boolean {
  return capabilities.some(
    (capability) => capability.kind === "chat_settings" && capability.version === BOT_CHAT_SETTINGS_VERSION,
  )
}
