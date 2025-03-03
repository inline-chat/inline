import { UsersModel } from "@in/server/db/models/users"
import {
  DeleteMessagesInput,
  DeleteMessagesResult,
  SendMessageInput,
  SendMessageResult,
  type GetMeInput,
  type GetMeResult,
} from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const sendMessage = async (
  input: SendMessageInput,
  handlerContext: HandlerContext,
): Promise<SendMessageResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid
  }

  let media = input.media?.media

  const result = await Functions.messages.sendMessage(
    {
      peerId: input.peerId,
      message: input.message,
      replyToMessageId: input.replyToMsgId,
      randomId: input.randomId,
      photoId: media?.oneofKind === "photo" ? media.photo.photoId : undefined,
      videoId: media?.oneofKind === "video" ? media.video.videoId : undefined,
      documentId: media?.oneofKind === "document" ? media.document.documentId : undefined,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { updates: result.updates }
}
