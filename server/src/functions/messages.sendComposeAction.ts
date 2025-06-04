import type { InputPeer, Update } from "@in/protocol/core"
import { UpdateComposeAction_ComposeAction } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"

type Input = {
  peer: InputPeer
  action?: UpdateComposeAction_ComposeAction
}

type Output = {}

export const sendComposeAction = async (input: Input, context: FunctionContext): Promise<Output> => {
  // Get the peer information - this validates the peer exists and user has access
  const peerId = await ChatModel.getChatFromInputPeer(input.peer, context)

  // Get all users who should receive this update (handles DMs and threads with multiple participants)
  const updateGroup = await getUpdateGroupFromInputPeer(input.peer, { currentUserId: context.currentUserId })

  // Send to all participants except the sender
  switch (updateGroup.type) {
    case "dmUsers": {
      const { userIds } = updateGroup
      for (const userId of userIds) {
        // Don't send compose action to the sender themselves
        if (userId !== context.currentUserId) {
          // For DMs, the recipient should see the sender as the peer
          const encodingForInputPeer: InputPeer = {
            type: { oneofKind: "user", user: { userId: BigInt(context.currentUserId) } },
          }

          const update: Update = {
            update: {
              oneofKind: "updateComposeAction",
              updateComposeAction: {
                userId: BigInt(context.currentUserId),
                peerId: encodePeerFromInputPeer({ inputPeer: encodingForInputPeer, currentUserId: userId }),
                action: input.action ?? UpdateComposeAction_ComposeAction.NONE,
              },
            },
          }

          RealtimeUpdates.pushToUser(userId, [update])
        }
      }
      break
    }

    case "threadUsers":
    case "spaceUsers": {
      const { userIds } = updateGroup
      for (const userId of userIds) {
        // Don't send compose action to the sender themselves
        if (userId !== context.currentUserId) {
          // For threads and spaces, everyone sees the same peer
          const update: Update = {
            update: {
              oneofKind: "updateComposeAction",
              updateComposeAction: {
                userId: BigInt(context.currentUserId),
                peerId: encodePeerFromInputPeer({ inputPeer: input.peer, currentUserId: userId }),
                action: input.action ?? UpdateComposeAction_ComposeAction.NONE,
              },
            },
          }

          RealtimeUpdates.pushToUser(userId, [update])
        }
      }
      break
    }
  }

  return {}
}
