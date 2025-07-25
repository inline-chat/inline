import type { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroupFromInputPeer } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

type Input = {
  messageIds: bigint[]
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const deleteMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)
  let { update } = await MessageModel.deleteMessages(input.messageIds, chatId)

  const { selfUpdates } = await pushUpdates({
    inputPeer: input.peer,
    messageIds: input.messageIds,
    currentUserId: context.currentUserId,
    update,
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
  update,
}: {
  inputPeer: InputPeer
  messageIds: bigint[]
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

  let selfUpdates: Update[] = []

  if (updateGroup.type === "dmUsers") {
    updateGroup.userIds.forEach((userId) => {
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
        seq: update.seq,
        date: encodeDateStrict(update.date),
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
  } else if (updateGroup.type === "threadUsers") {
    updateGroup.userIds.forEach((userId) => {
      // New updates
      let newMessageUpdate: Update = {
        update: {
          oneofKind: "deleteMessages",
          deleteMessages: {
            messageIds: messageIds.map((id) => BigInt(id)),
            peerId: Encoders.peerFromInputPeer({ inputPeer, currentUserId }),
          },
        },
        seq: update.seq,
        date: encodeDateStrict(update.date),
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
