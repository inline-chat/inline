import type { SendRichMessageDraftInput, SendRichMessageDraftResult } from "@inline-chat/protocol/core"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { ChatModel } from "@in/server/db/models/chats"
import { pushRichMessageDraftUpdate } from "@in/server/modules/message/richDraftUpdates"
import { RichTextValidationError } from "@in/server/modules/message/richText"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export async function sendRichMessageDraft(
  input: SendRichMessageDraftInput,
  handlerContext: HandlerContext,
): Promise<SendRichMessageDraftResult> {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
  const draftId = input.draftId.trim()
  if (!draftId) {
    throw RealtimeRpcError.BadRequest()
  }
  if (!input.clear && !input.richText) {
    throw RealtimeRpcError.BadRequest()
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, { currentUserId: handlerContext.userId })
  await AccessGuards.ensureChatAccess(chat, handlerContext.userId)

  try {
    await pushRichMessageDraftUpdate({
      inputPeer: input.peerId,
      currentUserId: handlerContext.userId,
      senderUserId: handlerContext.userId,
      draftId,
      messageId: input.messageId,
      richText: input.richText,
      clear: input.clear,
      ttlSeconds: input.ttlSeconds,
    })
  } catch (error) {
    if (error instanceof RichTextValidationError) {
      throw RealtimeRpcError.BadRequest()
    }
    throw error
  }

  return {}
}
