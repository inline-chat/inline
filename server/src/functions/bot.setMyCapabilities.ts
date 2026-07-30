import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import type { SetMyBotCapabilitiesInput, SetMyBotCapabilitiesResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "./_types"
import { getCurrentBotOrThrow, normalizeBotCapabilities, toProtocolBotCapability } from "./bot.capabilitiesShared"

export async function setMyBotCapabilities(
  input: SetMyBotCapabilitiesInput,
  context: FunctionContext,
): Promise<SetMyBotCapabilitiesResult> {
  const bot = await getCurrentBotOrThrow(context.currentUserId)
  const rows = await BotCapabilitiesModel.replaceForBotUserId(bot.id, normalizeBotCapabilities(input.capabilities))
  return {
    capabilities: rows.flatMap((capability) => {
      const encoded = toProtocolBotCapability(capability)
      return encoded ? [encoded] : []
    }),
  }
}
