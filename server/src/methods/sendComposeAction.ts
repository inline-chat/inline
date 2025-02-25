import { db } from "@in/server/db"
import { Type, type Static } from "@sinclair/typebox"
import { presenceManager } from "@in/server/ws/presence"
import { TComposeAction, TOptional, TPeerInfo, TUpdateComposeAction } from "@in/server/api-types"
import { Log } from "@in/server/utils/log"
import { peerFromInput, reversePeerId, TApiInputPeer, type HandlerContext } from "@in/server/controllers/helpers"
import { sendTransientUpdateFor } from "@in/server/modules/updates/sendUpdate"
import { ApiError, InlineError } from "@in/server/types/errors"
import { UpdateComposeAction_ComposeAction, type Update } from "@in/server/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"

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

  // Because we are sending the action to the other user, we need to reverse the peerId
  let otherPeerId = reversePeerId(peerId, context)

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
      },
    },
  })

  return undefined
}
