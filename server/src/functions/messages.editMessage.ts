import type { InputPeer, MessageEntities, Update } from "@in/protocol/core"
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
import { encodeDate, encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"

type Input = {
  messageId: bigint
  peer: InputPeer
  text: string
  entities?: MessageEntities
}

type Output = {
  updates: Update[]
}

export const editMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)
  const currentUserId = context.currentUserId
  const fullMessage = await MessageModel.getMessage(Number(input.messageId), chatId)

  const { message, update } = await MessageModel.editMessage({
    messageId: Number(input.messageId),
    chatId,
    text: input.text,
    entities: input.entities,
  })

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

  let { selfUpdates } = await pushUpdates({ inputPeer: input.peer, messageInfo, currentUserId, update })

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
  update,
}: {
  inputPeer: InputPeer
  messageInfo: MessageInfo
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

  let selfUpdates: Update[] = []

  if (updateGroup.type === "dmUsers") {
    updateGroup.userIds.forEach((userId) => {
      const encodingForUserId = userId
      const encodingForInputPeer: InputPeer =
        userId === currentUserId ? inputPeer : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

      let newMessageUpdate: Update = {
        date: encodeDateStrict(update.date),
        seq: update.seq,

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
  } else if (updateGroup.type === "threadUsers") {
    updateGroup.userIds.forEach((userId) => {
      // New updates
      let editMessageUpdate: Update = {
        date: encodeDateStrict(update.date),
        seq: update.seq,

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
          editMessageUpdate,
        ])
        selfUpdates = [
          // order matters here
          editMessageUpdate,
        ]
      } else {
        // other users get the message only
        RealtimeUpdates.pushToUser(userId, [editMessageUpdate])
      }
    })
  }

  return { selfUpdates, updateGroup }
}
