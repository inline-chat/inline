import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import {
  AGENT_CONFIGURATION_CAPABILITY_KIND,
  AGENT_CONFIGURATION_VERSION,
  decodeAgentConfigurationCatalog,
} from "@in/server/modules/agentConfiguration"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type {
  GetBotConfigurationCatalogInput,
  GetBotConfigurationCatalogResult,
} from "@inline-chat/protocol/core"
import type { FunctionContext } from "./_types"
import { requireManageableBot } from "./bot.avatarHelpers"
import { resolvePeerBotScope } from "./bot.peerDiscovery"

export async function getBotConfigurationCatalog(
  input: GetBotConfigurationCatalogInput,
  context: FunctionContext,
): Promise<GetBotConfigurationCatalogResult> {
  const botUserId = Number(input.botUserId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()

  if (input.peerId) {
    const { botUserIds } = await resolvePeerBotScope(input.peerId, context.currentUserId)
    if (!botUserIds.includes(botUserId)) throw RealtimeRpcError.UserIdInvalid()
  } else {
    await requireManageableBot(botUserId, context)
  }

  const capability = (await BotCapabilitiesModel.getForBotUserId(botUserId)).find(
    (item) => item.kind === AGENT_CONFIGURATION_CAPABILITY_KIND && item.version === AGENT_CONFIGURATION_VERSION,
  )
  return { catalog: decodeAgentConfigurationCatalog(capability?.payload ?? null) }
}
