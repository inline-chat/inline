import { SendMessageInput, SendMessageResult } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const sendMessage = async (
  input: SendMessageInput,
  handlerContext: HandlerContext,
): Promise<SendMessageResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
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
      voiceId: media?.oneofKind === "voice" ? media.voice.voiceId : undefined,
      nudge: media?.oneofKind === "nudge",
      sendDate: input.temporarySendDate ? Number(input.temporarySendDate) : undefined,
      isSticker: input.isSticker ?? false,
      entities: input.entities,
      actions: input.actions,
      // Structured content is laid over the literal text, so Markdown stays off.
      parseMarkdown: input.blockContent ? input.parseMarkdown : input.parseMarkdown ?? (handlerContext.isBot ? true : undefined),
      botBlockContent: input.blockContent,
      sendMode: input.sendMode ?? undefined,
      initialAgentContext: input.initialAgentContext,
      sourceChatId: input.sourceChatId === undefined ? undefined : Number(input.sourceChatId),
      // Legacy sockets know whether they belong to a bot; V3 leaves it to a cached lookup.
      paceBotSender: { isBot: handlerContext.isBot },
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
      isBot: handlerContext.isBot,
    },
  )

  return { updates: result.updates }
}
