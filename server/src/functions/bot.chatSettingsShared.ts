import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import { BOT_CHAT_SETTINGS_VERSION, hasChatSettingsCapability } from "./bot.capabilitiesShared"
import { resolvePeerBotScope } from "./bot.peerDiscovery"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { InputPeer } from "@inline-chat/protocol/core"

export async function resolveCapableBotForPeer(input: {
  peerId?: InputPeer
  botUserId: bigint
  version: number
  actorUserId: number
}): Promise<{ botUserId: number; chatId: number }> {
  if (input.version !== BOT_CHAT_SETTINGS_VERSION) throw RealtimeRpcError.BadRequest()
  const botUserId = Number(input.botUserId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()

  const { chat, botUserIds } = await resolvePeerBotScope(input.peerId, input.actorUserId)
  if (!botUserIds.includes(botUserId)) throw RealtimeRpcError.UserIdInvalid()

  const capabilities = await BotCapabilitiesModel.getForBotUserId(botUserId)
  if (!hasChatSettingsCapability(capabilities)) throw RealtimeRpcError.BadRequest()
  return { botUserId, chatId: chat.id }
}
