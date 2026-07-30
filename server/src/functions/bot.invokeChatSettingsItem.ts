import type { FunctionContext } from "./_types"
import { resolveCapableBotForPeer } from "./bot.chatSettingsShared"
import { botChatSettingsBroker } from "@in/server/modules/botChatSettings/broker"
import {
  normalizeBotChatSettingsItemId,
  normalizeBotChatSettingsRevision,
  normalizeBotChatSettingsValue,
  unreachableBotChatSettingsResponse,
} from "@in/server/modules/botChatSettings/validation"
import { sendMessageToRealtimeBot } from "@in/server/realtime/message"
import type { InvokeBotChatSettingsItemInput, InvokeBotChatSettingsItemResult } from "@inline-chat/protocol/core"

export async function invokeBotChatSettingsItem(
  input: InvokeBotChatSettingsItemInput,
  context: FunctionContext,
): Promise<InvokeBotChatSettingsItemResult> {
  const target = await resolveCapableBotForPeer({
    peerId: input.peerId,
    botUserId: input.botUserId,
    version: input.version,
    actorUserId: context.currentUserId,
  })
  const itemId = normalizeBotChatSettingsItemId(input.itemId)
  const documentRevision = normalizeBotChatSettingsRevision(input.documentRevision)
  const value = normalizeBotChatSettingsValue(input.value)
  const pending = botChatSettingsBroker.create({
    botUserId: target.botUserId,
    actorUserId: context.currentUserId,
    chatId: target.chatId,
  })
  const recipientCount = await sendMessageToRealtimeBot(target.botUserId, {
    oneofKind: "bot",
    bot: {
      event: {
        oneofKind: "chatSettingsItemInvoked",
        chatSettingsItemInvoked: {
          requestId: pending.requestId,
          chatId: BigInt(target.chatId),
          actorUserId: BigInt(context.currentUserId),
          version: input.version,
          itemId,
          value,
          documentRevision,
        },
      },
    },
  })
  if (recipientCount === 0) {
    botChatSettingsBroker.resolveSystem(pending.requestId, unreachableBotChatSettingsResponse())
  }
  return { response: await pending.response }
}
