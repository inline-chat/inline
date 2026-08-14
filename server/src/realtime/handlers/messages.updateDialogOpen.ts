import { Method, UpdateDialogOpenInput, UpdateDialogOpenResult } from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { queueEmptyUntitledThreadDeletionAfterClose } from "@in/server/functions/messages.deleteChat"

export const method = Method.UPDATE_DIALOG_OPEN

export const updateDialogOpen = async (
  input: UpdateDialogOpenInput,
  handlerContext: HandlerContext,
): Promise<UpdateDialogOpenResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const context = {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  }
  const result = await Functions.messages.updateDialogOpen(
    { peerId: input.peerId, open: input.open, order: input.order },
    context,
  )

  const chat = result.chat
  const isEmptyUntitledThreadOwnedByCurrentUser =
    chat?.peerId?.type.oneofKind === "chat" &&
    chat.untitled === true &&
    chat.createdBy === BigInt(handlerContext.userId) &&
    chat.lastMsgId == null

  if (!input.open && chat && isEmptyUntitledThreadOwnedByCurrentUser) {
    queueEmptyUntitledThreadDeletionAfterClose(Number(chat.id), context)
  }

  return result
}
