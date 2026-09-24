import type { FunctionContext } from "./_types"
import { resolveCapableBotForPeer } from "./bot.chatSettingsShared"
import { botChatSettingsBroker } from "@in/server/modules/botChatSettings/broker"
import { normalizeBotChatSettingsResponse, unreachableBotChatSettingsResponse } from "@in/server/modules/botChatSettings/validation"
import { getRealtimeBotConnection, sendMessageToRealtimeBotConnection } from "@in/server/realtime/message"
import { BotChatSettingsResponse, ServerMessage, type RequestBotChatSettingsInput, type RequestBotChatSettingsResult } from "@inline-chat/protocol/core"
import { requestRemoteBot } from "@in/server/modules/internalMessaging/privateBot"

export async function requestBotChatSettings(
  input: RequestBotChatSettingsInput,
  context: FunctionContext,
): Promise<RequestBotChatSettingsResult> {
  const target = await resolveCapableBotForPeer({
    peerId: input.peerId,
    botUserId: input.botUserId,
    version: input.version,
    actorUserId: context.currentUserId,
  })
  const pending = botChatSettingsBroker.create({
    botUserId: target.botUserId,
    actorUserId: context.currentUserId,
    chatId: target.chatId,
    operation: "request",
  })
  const payload: ServerMessage["payload"] = {
    oneofKind: "bot",
    bot: { event: { oneofKind: "chatSettingsRequested", chatSettingsRequested: {
      requestId: pending.requestId, chatId: BigInt(target.chatId), actorUserId: BigInt(context.currentUserId), version: input.version,
    } } },
  }
  let recipientCount = 0
  try {
    const local = getRealtimeBotConnection(target.botUserId)
    if (local) {
      recipientCount = await sendMessageToRealtimeBotConnection(target.botUserId, local.connectionId, payload) ? 1 : 0
    } else {
      const remote = await requestRemoteBot({
        botUserId: target.botUserId, actorUserId: context.currentUserId,
        actorSessionId: context.currentSessionId, actorConnectionId: context.currentConnectionId,
        requestId: pending.requestId, kind: "botSettings", payload,
      })
      if (remote.status === "replied") {
        const response = normalizeBotChatSettingsResponse(BotChatSettingsResponse.fromBinary(Buffer.from(remote.response, "base64")))
        botChatSettingsBroker.answer(pending.requestId, target.botUserId, response)
        recipientCount = 1
      }
    }
  } catch (error) {
    botChatSettingsBroker.resolveSystem(
      pending.requestId,
      unreachableBotChatSettingsResponse(),
      "dispatch_failure",
    )
    throw error
  }
  botChatSettingsBroker.markDispatched(pending.requestId, recipientCount)
  if (recipientCount === 0) {
    botChatSettingsBroker.resolveSystem(pending.requestId, unreachableBotChatSettingsResponse(), "no_recipient")
  }
  const response = await pending.response
  // A bot may answer after access or capabilities changed while we waited.
  await resolveCapableBotForPeer({
    peerId: input.peerId,
    botUserId: input.botUserId,
    version: input.version,
    actorUserId: context.currentUserId,
  })
  return { response }
}
