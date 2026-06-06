import type { SetBotPresenceStateInput, SetBotPresenceStateResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { setBotPresenceStateFn } from "@in/server/functions/bot.setPresenceState"

export const setBotPresenceStateHandler = async (
  input: SetBotPresenceStateInput,
  handlerContext: HandlerContext,
): Promise<SetBotPresenceStateResult> =>
  setBotPresenceStateFn(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
