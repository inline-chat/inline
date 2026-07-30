import { invokeBotChatSettingsItem } from "@in/server/functions/bot.invokeChatSettingsItem"
import type { HandlerContext } from "@in/server/realtime/types"
import type { InvokeBotChatSettingsItemInput, InvokeBotChatSettingsItemResult } from "@inline-chat/protocol/core"

export const invokeBotChatSettingsItemHandler = (
  input: InvokeBotChatSettingsItemInput,
  context: HandlerContext,
): Promise<InvokeBotChatSettingsItemResult> =>
  invokeBotChatSettingsItem(input, { currentSessionId: context.sessionId, currentUserId: context.userId })
