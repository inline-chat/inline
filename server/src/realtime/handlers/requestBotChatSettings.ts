import { requestBotChatSettings } from "@in/server/functions/bot.requestChatSettings"
import type { HandlerContext } from "@in/server/realtime/types"
import type { RequestBotChatSettingsInput, RequestBotChatSettingsResult } from "@inline-chat/protocol/core"

export const requestBotChatSettingsHandler = (
  input: RequestBotChatSettingsInput,
  context: HandlerContext,
): Promise<RequestBotChatSettingsResult> =>
  requestBotChatSettings(input, { currentSessionId: context.sessionId, currentUserId: context.userId })
