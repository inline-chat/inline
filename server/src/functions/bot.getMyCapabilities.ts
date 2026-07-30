import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import type { GetMyBotCapabilitiesResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "./_types"
import { getCurrentBotOrThrow, toProtocolBotCapability } from "./bot.capabilitiesShared"

export async function getMyBotCapabilities(context: FunctionContext): Promise<GetMyBotCapabilitiesResult> {
  const bot = await getCurrentBotOrThrow(context.currentUserId)
  const capabilities = await BotCapabilitiesModel.getForBotUserId(bot.id)
  return {
    capabilities: capabilities.flatMap((capability) => {
      const encoded = toProtocolBotCapability(capability)
      return encoded ? [encoded] : []
    }),
  }
}
