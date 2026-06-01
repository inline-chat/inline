import type { DeleteMessageAttachmentInput, DeleteMessageAttachmentResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const deleteMessageAttachment = async (
  input: DeleteMessageAttachmentInput,
  context: HandlerContext,
): Promise<DeleteMessageAttachmentResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  if (input.messageId <= 0n || input.attachmentId <= 0n) {
    throw RealtimeRpcError.BadRequest()
  }

  return Functions.messages.deleteMessageAttachment(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
}
