import type { FunctionContext } from "./_types"
import { getCurrentBotOrThrow } from "./bot.capabilitiesShared"
import { botChatSettingsBroker } from "@in/server/modules/botChatSettings/broker"
import {
  invalidBotChatSettingsResponse,
  normalizeBotChatSettingsResponse,
} from "@in/server/modules/botChatSettings/validation"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { BotChatSettingsResponse, type AnswerBotChatSettingsInput, type AnswerBotChatSettingsResult } from "@inline-chat/protocol/core"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"

export async function answerBotChatSettings(
  input: AnswerBotChatSettingsInput,
  context: FunctionContext,
): Promise<AnswerBotChatSettingsResult> {
  const bot = await getCurrentBotOrThrow(context.currentUserId)
  let response
  try {
    response = normalizeBotChatSettingsResponse(input.response)
  } catch (error) {
    const invalid = invalidBotChatSettingsResponse()
    if (botChatSettingsBroker.answer(input.requestId, bot.id, invalid) === "missing" && context.currentConnectionId) {
      await internalMessaging.replyInboundPrivate({ kind: "botSettings", requestId: input.requestId,
        actualConnectionId: context.currentConnectionId, botUserId: bot.id,
        actualSessionId: context.currentSessionId,
        payload: { kind: "botSettings", response: Buffer.from(BotChatSettingsResponse.toBinary(invalid)).toString("base64") } })
    }
    throw error
  }
  const outcome = botChatSettingsBroker.answer(input.requestId, bot.id, response)
  if (outcome === "wrong_bot") {
    throw RealtimeRpcError.BadRequest()
  }
  if (outcome === "missing") {
    // An already-expired local request historically accepts a late valid
    // answer. Only a live directed request needs exact connection matching.
    if (!internalMessaging.hasInboundPrivate("botSettings", input.requestId)) return {}
    if (!context.currentConnectionId || !await internalMessaging.replyInboundPrivate({
      kind: "botSettings", requestId: input.requestId, actualConnectionId: context.currentConnectionId,
      actualSessionId: context.currentSessionId,
      botUserId: bot.id,
      payload: { kind: "botSettings", response: Buffer.from(BotChatSettingsResponse.toBinary(response)).toString("base64") },
    })) throw RealtimeRpcError.BadRequest()
  }
  return {}
}
