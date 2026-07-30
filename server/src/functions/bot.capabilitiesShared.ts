import { db } from "@in/server/db"
import { userNotDeleted, users, type DbBotCapability, type DbUser } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { BotCapability_Kind, type BotCapability } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"

export const BOT_CAPABILITY_LIMIT = 100
export const BOT_CHAT_SETTINGS_VERSION = 1

const capabilityKindToStorage = (kind: BotCapability_Kind): string | undefined =>
  kind === BotCapability_Kind.CHAT_SETTINGS ? "chat_settings" : undefined

const capabilityKindFromStorage = (kind: string): BotCapability_Kind | undefined =>
  kind === "chat_settings" ? BotCapability_Kind.CHAT_SETTINGS : undefined

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
): Array<{ kind: string; version: number }> {
  if (!capabilities) return []
  if (capabilities.length > BOT_CAPABILITY_LIMIT) throw RealtimeRpcError.BadRequest()

  const seen = new Set<string>()
  return capabilities.map((capability) => {
    const kind = capabilityKindToStorage(capability.kind)
    if (
      !kind ||
      seen.has(kind) ||
      !Number.isSafeInteger(capability.version) ||
      capability.version !== BOT_CHAT_SETTINGS_VERSION
    ) {
      throw RealtimeRpcError.BadRequest()
    }
    seen.add(kind)
    return { kind, version: capability.version }
  })
}

export function toProtocolBotCapability(
  capability: Pick<DbBotCapability, "kind" | "version">,
): BotCapability | undefined {
  const kind = capabilityKindFromStorage(capability.kind)
  return kind ? { kind, version: capability.version } : undefined
}

export function hasChatSettingsCapability(
  capabilities: ReadonlyArray<Pick<DbBotCapability, "kind" | "version">>,
): boolean {
  return capabilities.some(
    (capability) => capability.kind === "chat_settings" && capability.version === BOT_CHAT_SETTINGS_VERSION,
  )
}
