import type { FunctionContext } from "./_types"
import { resolveCapableBotForPeer } from "./bot.chatSettingsShared"
import { botChatSettingsBroker } from "@in/server/modules/botChatSettings/broker"
import { unreachableBotChatSettingsResponse } from "@in/server/modules/botChatSettings/validation"
import { sendMessageToRealtimeBot } from "@in/server/realtime/message"
import type { RequestBotChatSettingsInput, RequestBotChatSettingsResult } from "@inline-chat/protocol/core"

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
  })
  const recipientCount = await sendMessageToRealtimeBot(target.botUserId, {
    oneofKind: "bot",
    bot: {
      event: {
        oneofKind: "chatSettingsRequested",
        chatSettingsRequested: {
          requestId: pending.requestId,
          chatId: BigInt(target.chatId),
          actorUserId: BigInt(context.currentUserId),
          version: input.version,
        },
      },
    },
  })
  if (recipientCount === 0) {
    botChatSettingsBroker.resolveSystem(pending.requestId, unreachableBotChatSettingsResponse())
  }
  return { response: await pending.response }
}
