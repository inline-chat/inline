import type { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { ReactionModel } from "../db/models/reactions"
import { Log } from "../utils/log"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import { connectionManager } from "../ws/connections"

type Input = {
  messageId: bigint
  peer: InputPeer
  text: string
}

type Output = {
  updates: Update[]
}

export const editMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)
  const currentUserId = context.currentUserId
  const encodingForInputPeer: InputPeer =
    currentUserId === currentUserId
      ? input.peer
      : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }
  const fullMessage = await MessageModel.getMessage(Number(input.messageId), chatId)

  const message = await MessageModel.editMessage(Number(input.messageId), chatId, input.text)

  if (!message) {
    Log.shared.error("Message not found")
    throw new Error("Message not found")
  }

  const messageInfo: MessageInfo = {
    message: message,
    photo: fullMessage.photo ?? undefined,
    video: fullMessage.video ?? undefined,
    document: fullMessage.document ?? undefined,
  }

  let { selfUpdates, updateGroup } = await pushUpdates({ inputPeer: input.peer, messageInfo, currentUserId })

  return { updates: selfUpdates }
}

type EncodeMessageInput = Parameters<typeof Encoders.message>[0]
type MessageInfo = Omit<EncodeMessageInput, "encodingForUserId" | "encodingForPeer">

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

/** Push updates for edit messages */
const pushUpdates = async ({
  inputPeer,
  messageInfo,
  currentUserId,
}: {
  inputPeer: InputPeer
  messageInfo: MessageInfo
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
          oneofKind: "editMessage",
          editMessage: {
            message: Encoders.message({
              ...messageInfo,
              encodingForPeer: { inputPeer: encodingForInputPeer },
              encodingForUserId,
            }),
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
          oneofKind: "editMessage",
          editMessage: {
            message: Encoders.message({
              ...messageInfo,
              encodingForPeer: { inputPeer },
              encodingForUserId: userId,
            }),
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
