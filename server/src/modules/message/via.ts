import type { InputMessageVia, MessageVia } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UsersModel } from "@in/server/db/models/users"
import { VIA_AGENTS, knownViaApp } from "@in/server/modules/message/viaAgents"

export { GENERIC_VIA_AGENT, VIA_AGENTS, knownViaApp } from "@in/server/modules/message/viaAgents"

export type ViaColumns = { viaApp: string | null; viaBotUserId: number | null; viaName: string | null }

const NO_VIA: ViaColumns = { viaApp: null, viaBotUserId: null, viaName: null }

/** Longest stored bot name; matches messages.via_name. */
const VIA_NAME_MAX_LENGTH = 64

/**
 * Validates how a message names the agent sending it. Bots always send as
 * themselves. A bot signer must be one the sender owns.
 */
export const resolveMessageVia = async (input: {
  via: InputMessageVia | undefined
  currentUserId: number
  senderIsBot: () => Promise<boolean>
}): Promise<ViaColumns> => {
  const source = input.via?.source
  if (!source || source.oneofKind === undefined) return NO_VIA
  if (await input.senderIsBot()) return NO_VIA

  switch (source.oneofKind) {
    case "app":
      return { viaApp: knownViaApp(source.app), viaBotUserId: null, viaName: null }
    case "botUserId": {
      const botUserId = Number(source.botUserId)
      const bot = Number.isSafeInteger(botUserId) && botUserId > 0 ? await UsersModel.getUserById(botUserId) : undefined
      if (!bot || bot.bot !== true || bot.deleted === true || bot.botCreatorId !== input.currentUserId) {
        throw RealtimeRpcError.BadRequestWithReason("via bot must be a bot you own")
      }
      return { viaApp: null, viaBotUserId: botUserId, viaName: botDisplayName(bot) }
    }
  }
}

export const encodeMessageVia = (message: Partial<ViaColumns>): MessageVia | undefined => {
  if (message.viaBotUserId != null) {
    return {
      source: { oneofKind: "botUserId", botUserId: BigInt(message.viaBotUserId) },
      ...(message.viaName ? { name: message.viaName } : {}),
    }
  }
  if (message.viaApp != null) {
    const app = knownViaApp(message.viaApp)
    return { source: { oneofKind: "app", app }, name: VIA_AGENTS[app] }
  }
  return undefined
}

/**
 * The bot's name as people see it, kept with the message like a forward's
 * from_name, so recipients who can't see the bot still read who signed.
 */
const botDisplayName = (bot: { firstName: string | null; lastName: string | null; username: string | null }): string | null => {
  const name = [bot.firstName, bot.lastName].filter(Boolean).join(" ").trim() || bot.username?.trim() || ""
  return name ? Array.from(name).slice(0, VIA_NAME_MAX_LENGTH).join("") : null
}
