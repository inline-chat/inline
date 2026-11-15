import type { SendComposeSuggestionInput, SendComposeSuggestionResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sendComposeSuggestion } from "@in/server/functions/messages.sendComposeSuggestion"

export const sendComposeSuggestionHandler = async (
  input: SendComposeSuggestionInput,
  handlerContext: HandlerContext,
): Promise<SendComposeSuggestionResult> => {
  if (!input.peerId) throw RealtimeRpcError.PeerIdInvalid()
  if (input.userId <= 0n) throw RealtimeRpcError.BadRequest()

  await sendComposeSuggestion(
    { peer: input.peerId, userId: Number(input.userId), text: input.text, afterMessageId: input.afterMessageId },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
      currentConnectionId: handlerContext.connectionId,
      isBot: handlerContext.isBot,
    },
  )
  return {}
}
