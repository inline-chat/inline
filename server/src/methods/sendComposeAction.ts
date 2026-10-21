import { Type, type Static } from "@sinclair/typebox"
import {
  TComposeAction,
  TOptional,
  TPeerInfo,
  TUpdateComposeAction,
  type TPeerInfo as PeerInfo,
} from "@in/server/api-types"
import { sendTransientUpdateFor } from "@in/server/modules/updates/sendUpdate"
import { getChatFromPeer } from "@in/server/db/models/chats"
import { getAuthorizedChat } from "@in/server/modules/authorization/legacyAccessGuards"
import { InlineError } from "@in/server/types/errors"
import { normalizeId, TInputId } from "@in/server/types/methods"

type HandlerContext = {
  readonly currentUserId: number
}

const TApiInputPeer = {
  peerId: TOptional(TPeerInfo),
  peerUserId: TOptional(TInputId),
  peerThreadId: TOptional(TInputId),
} as const

const peerFromInput = (input: {
  readonly peerId?: PeerInfo | null | undefined
  readonly peerUserId?: number | string | null | undefined
  readonly peerThreadId?: number | string | null | undefined
}): PeerInfo => {
  if (input.peerUserId) return { userId: normalizeId(input.peerUserId) }
  if (input.peerThreadId) return { threadId: normalizeId(input.peerThreadId) }
  if (input.peerId) return input.peerId
  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

const reversePeerId = (peerId: PeerInfo, currentUserId: number): PeerInfo =>
  "userId" in peerId ? { userId: currentUserId } : { threadId: peerId.threadId }

export const Input = Type.Object({
  action: TOptional(TComposeAction),

  // Peer - where user is typing
  ...TApiInputPeer,
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  let { currentUserId } = context

  let peerId = peerFromInput(input)

  // The recipient group is not authorization. Require the actor's current
  // access to the DM or thread before emitting typing state to its members.
  // Legacy guard maps denial to PEER_INVALID (a 4xx), not an internal error.
  const chat = await getChatFromPeer(peerId, { currentUserId })
  await getAuthorizedChat(chat.id, currentUserId)

  // Because we are sending the action to the other user, we need to reverse the peerId
  let otherPeerId = reversePeerId(peerId, context.currentUserId)

  let update: TUpdateComposeAction = {
    // Chat the action took place in for the target user/thread
    peerId: otherPeerId,
    userId: currentUserId,
    action: input.action,
  }

  await sendTransientUpdateFor({
    reason: {
      composeAction: {
        update,

        // Who should receive the event
        target: peerId,
        otherPeerId,
      },
    },
  })

  return undefined
}
