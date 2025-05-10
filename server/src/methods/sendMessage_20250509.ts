import { InlineError } from "@in/server/types/errors"
import { type Static, Type } from "@sinclair/typebox"
import { TInputPeerInfo, TMessageInfo, Optional, TPeerInfo } from "@in/server/api-types"
import type { HandlerContext } from "../controllers/helpers"
import { TInputId } from "@in/server/types/methods"
import { Functions } from "@in/server/functions"
import { ProtocolConvertors } from "@in/server/types/protocolConvertors"

export const Input = Type.Object({
  peerId: Optional(TInputPeerInfo),
  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),
  text: Optional(Type.String()),
  photoId: Optional(TInputId),
})

type Input = Static<typeof Input>

export const Response = Type.Object({})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: HandlerContext): Promise<Response> => {
  const messageDate = new Date()

  const peerId: TPeerInfo | null | undefined = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: Number(input.peerThreadId) }
    : input.peerId

  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  let inputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer(peerId)

  const _ = await Functions.messages.sendMessage(
    {
      peerId: inputPeer,
      message: input.text ?? undefined,
      photoId: input.photoId ? BigInt(input.photoId) : undefined,
      sendDate: Math.floor(messageDate.getTime() / 1000),
      isSticker: false,
    },
    {
      currentSessionId: context.currentSessionId,
      currentUserId: context.currentUserId,
    },
  )

  return {
    // TODO
  }
}
