import type { UpdateDialogTranslationInput, UpdateDialogTranslationResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export async function updateDialogTranslation(
  input: UpdateDialogTranslationInput,
  context: HandlerContext,
): Promise<UpdateDialogTranslationResult> {
  if (!input.peerId) throw RealtimeRpcError.PeerIdInvalid()
  if (input.enabled === undefined) throw RealtimeRpcError.BadRequest()
  return Functions.messages.updateDialogTranslation(
    { peerId: input.peerId, enabled: input.enabled, importLegacyEnabled: input.importLegacyEnabled },
    { currentUserId: context.userId, currentSessionId: context.sessionId },
  )
}
