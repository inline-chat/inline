import { answerBotChatSettings } from "@in/server/functions/bot.answerChatSettings"
import type { HandlerContext } from "@in/server/realtime/types"
import type { AnswerBotChatSettingsInput, AnswerBotChatSettingsResult } from "@inline-chat/protocol/core"

export const answerBotChatSettingsHandler = (
  input: AnswerBotChatSettingsInput,
  context: HandlerContext,
): Promise<AnswerBotChatSettingsResult> =>
  answerBotChatSettings(input, { currentSessionId: context.sessionId, currentUserId: context.userId })
