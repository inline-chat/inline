import { InlineError } from "@in/server/types/errors"
import { Optional, type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { TInputId } from "@in/server/types/methods"
import type { InputPeer } from "@inline-chat/protocol/core"
import { readMessages as readMessagesFunction } from "@in/server/functions/messages.readMessages"

export const Input = Type.Object({
  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),

  maxId: Optional(Type.Integer()), // max message id to mark as read
})

export const Response = Type.Object({
  // unreadCount: Type.Integer(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const peerUserId = input.peerUserId ? Number(input.peerUserId) : undefined
  const peerThreadId = input.peerThreadId ? Number(input.peerThreadId) : undefined

  if (!peerUserId && !peerThreadId) {
    // requires either peerUserId or peerThreadId
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  if (peerUserId && peerThreadId) {
    // cannot have both peerUserId and peerThreadId
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  let inputPeer: InputPeer
  if (peerUserId !== undefined) {
    inputPeer = { type: { oneofKind: "user", user: { userId: BigInt(peerUserId) } } }
  } else if (peerThreadId !== undefined) {
    inputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(peerThreadId) } } }
  } else {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }
  await readMessagesFunction(
    { peer: inputPeer, maxId: input.maxId },
    { currentSessionId: context.currentSessionId, currentUserId: context.currentUserId },
  )

  return {}
}
