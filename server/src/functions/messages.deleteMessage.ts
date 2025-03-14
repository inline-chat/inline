import type { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroupFromInputPeer } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import { connectionManager } from "../ws/connections"
import { Log } from "../utils/log"

type Input = {
  messageIds: bigint[]
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const deleteMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)
  await MessageModel.deleteMessages(input.messageIds, chatId)

  const { selfUpdates, updateGroup } = await pushUpdates({
    inputPeer: input.peer,
    messageIds: input.messageIds,
    currentUserId: context.currentUserId,
  })

  return { updates: selfUpdates }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

/** Push updates for delete messages */
const pushUpdates = async ({
  inputPeer,
  messageIds,
  currentUserId,
}: {
  inputPeer: InputPeer
  messageIds: bigint[]
  currentUserId: number
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

  let selfUpdates: Update[] = []

  if (updateGroup.type === "users") {
    updateGroup.userIds.forEach((userId) => {
      const encodingForUserId = userId
      const encodingForInputPeer: InputPeer =
        userId === currentUserId ? inputPeer : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

      let newMessageUpdate: Update = {
        update: {
          oneofKind: "deleteMessages",
          deleteMessages: {
            messageIds: messageIds.map((id) => BigInt(id)),
            peerId: Encoders.peerFromInputPeer({ inputPeer: encodingForInputPeer, currentUserId }),
          },
        },
      }

      if (userId === currentUserId) {
        // current user gets the message id update and new message update
        RealtimeUpdates.pushToUser(userId, [
          // order matters here
          newMessageUpdate,
        ])
        selfUpdates = [
          // order matters here
          newMessageUpdate,
        ]
      } else {
        // other users get the message only
        RealtimeUpdates.pushToUser(userId, [newMessageUpdate])
      }
    })
  } else if (updateGroup.type === "space") {
    const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
    Log.shared.debug(`Sending message to space ${updateGroup.spaceId}`, { userIds })
    userIds.forEach((userId) => {
      // New updates
      let newMessageUpdate: Update = {
        update: {
          oneofKind: "deleteMessages",
          deleteMessages: {
            messageIds: messageIds.map((id) => BigInt(id)),
            peerId: Encoders.peerFromInputPeer({ inputPeer, currentUserId }),
          },
        },
      }

      if (userId === currentUserId) {
        // current user gets the message id update and new message update
        RealtimeUpdates.pushToUser(userId, [
          // order matters here
          newMessageUpdate,
        ])
        selfUpdates = [
          // order matters here
          newMessageUpdate,
        ]
      } else {
        // other users get the message only
        RealtimeUpdates.pushToUser(userId, [newMessageUpdate])
      }
    })
  }

  return { selfUpdates, updateGroup }
}
