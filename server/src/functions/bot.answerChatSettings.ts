import type { FunctionContext } from "./_types"
import { getCurrentBotOrThrow } from "./bot.capabilitiesShared"
import { botChatSettingsBroker } from "@in/server/modules/botChatSettings/broker"
import {
  invalidBotChatSettingsResponse,
  normalizeBotChatSettingsResponse,
} from "@in/server/modules/botChatSettings/validation"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { AnswerBotChatSettingsInput, AnswerBotChatSettingsResult } from "@inline-chat/protocol/core"

export async function answerBotChatSettings(
  input: AnswerBotChatSettingsInput,
  context: FunctionContext,
): Promise<AnswerBotChatSettingsResult> {
  const bot = await getCurrentBotOrThrow(context.currentUserId)
  let response
  try {
    response = normalizeBotChatSettingsResponse(input.response)
  } catch (error) {
    botChatSettingsBroker.answer(input.requestId, bot.id, invalidBotChatSettingsResponse())
    throw error
  }
  if (!botChatSettingsBroker.answer(input.requestId, bot.id, response)) {
    throw RealtimeRpcError.BadRequest()
  }
  return {}
}
