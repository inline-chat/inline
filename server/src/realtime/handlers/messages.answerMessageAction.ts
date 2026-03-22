import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import type { AnswerMessageActionInput, AnswerMessageActionResult } from "@inline-chat/protocol/core"

export const answerMessageAction = async (
  input: AnswerMessageActionInput,
  handlerContext: HandlerContext,
): Promise<AnswerMessageActionResult> => {
  await Functions.messages.answerMessageAction(
    {
      interactionId: input.interactionId,
      ui: input.ui,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {}
}
