import { setMyBotCapabilities } from "@in/server/functions/bot.setMyCapabilities"
import type { HandlerContext } from "@in/server/realtime/types"
import type { SetMyBotCapabilitiesInput, SetMyBotCapabilitiesResult } from "@inline-chat/protocol/core"

export const setMyBotCapabilitiesHandler = (
  input: SetMyBotCapabilitiesInput,
  context: HandlerContext,
): Promise<SetMyBotCapabilitiesResult> =>
  setMyBotCapabilities(input, { currentSessionId: context.sessionId, currentUserId: context.userId })
