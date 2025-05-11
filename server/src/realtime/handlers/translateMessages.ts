import { RealtimeRpcError } from "@in/server/realtime/errors"
import { translateMessages } from "@in/server/functions/translateMessages"
import { InputPeer, TranslateMessagesInput, TranslateMessagesResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import type { FunctionContext } from "@in/server/functions/_types"

export async function handleTranslateMessages(
  input: TranslateMessagesInput,
  context: HandlerContext,
): Promise<TranslateMessagesResult> {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid
  }

  if (!input.language) {
    throw RealtimeRpcError.BadRequest
  }

  const functionsContext: FunctionContext = {
    currentUserId: context.userId,
    currentSessionId: context.sessionId,
  }

  const { translations } = await translateMessages(
    {
      peerId: input.peerId,
      messageIds: input.messageIds.map((id) => Number(id)),
      language: input.language,
    },
    functionsContext,
  )

  return {
    translations,
  }
}
