import type { AcknowledgeMessagesInput, AcknowledgeMessagesResult } from "@inline-chat/protocol/core"
import { acknowledgeMessages } from "@in/server/functions/messages.acknowledgeMessages"
import type { HandlerContext } from "@in/server/realtime/types"

export function acknowledgeMessagesHandler(input: AcknowledgeMessagesInput, context: HandlerContext): Promise<AcknowledgeMessagesResult> {
  return acknowledgeMessages(input, { currentUserId: context.userId, currentSessionId: context.sessionId })
}
