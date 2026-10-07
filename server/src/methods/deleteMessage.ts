import { getAuthorizedChat } from "@in/server/modules/authorization/legacyAccessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { deleteMessage as canonicalDeleteMessage } from "@in/server/functions/messages.deleteMessage"
import { InlineError } from "@in/server/types/errors"
import { type Static, Type } from "@sinclair/typebox"
import { TPeerInfo } from "@in/server/api-types"
import { TInputId } from "@in/server/types/methods"
import { getChatIdFromPeer } from "@in/server/methods/sendMessage"

export const Input = Type.Object({
  messageId: TInputId,
  chatId: TInputId,
  peerUserId: Type.Optional(TInputId),
  peerThreadId: Type.Optional(TInputId),
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Undefined()

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  const messageId = Number(input.messageId)
  if (!Number.isInteger(messageId) || messageId <= 0 || messageId > 2_147_483_647) {
    throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
  }

  const chatId = Number(input.chatId)
  if (!Number.isInteger(chatId) || chatId <= 0 || chatId > 2_147_483_647) {
    throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
  }

  if ((input.peerUserId && input.peerThreadId) || (!input.peerUserId && !input.peerThreadId)) {
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  const peerId: TPeerInfo = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : { threadId: Number(input.peerThreadId) }

  const peerChatId = await getChatIdFromPeer(peerId, context)
  if (peerChatId !== chatId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  await getAuthorizedChat(chatId, context.currentUserId)
  try {
    await canonicalDeleteMessage(
      {
        peer:
          "userId" in peerId
            ? { type: { oneofKind: "user", user: { userId: BigInt(peerId.userId) } } }
            : { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
        messageIds: [BigInt(messageId)],
      },
      { currentUserId: context.currentUserId, currentSessionId: 0 },
    )
  } catch (error) {
    if (error instanceof RealtimeRpcError) {
      const mapped =
        error.code === RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED
          ? InlineError.ApiError.SPACE_ADMIN_REQUIRED
          : error.code === RealtimeRpcError.Code.AGENT_SESSION_MESSAGE_IMMUTABLE
          ? InlineError.ApiError.AGENT_SESSION_MESSAGE_IMMUTABLE
          : error.code === RealtimeRpcError.Code.MESSAGE_ID_INVALID
          ? InlineError.ApiError.MSG_ID_INVALID
          : error.code === RealtimeRpcError.Code.PEER_ID_INVALID
          ? InlineError.ApiError.PEER_INVALID
          : InlineError.ApiError.BAD_REQUEST
      throw new InlineError(mapped)
    }
    throw error
  }
}
