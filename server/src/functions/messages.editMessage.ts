import type { InputPeer, MessageActions, MessageEntities, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "../utils/log"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { processOutgoingText } from "@in/server/modules/message/processOutgoingText"
import { normalizeAndValidateMessageActions } from "@in/server/modules/message/messageActions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { queueMessageThreadLinkMaterialization } from "@in/server/modules/threadGraph"
import { resolveThreadTitleLinks } from "@in/server/modules/message/resolveThreadTitleLinks"

type Input = {
  messageId: bigint
  peer: InputPeer
  text: string
  entities?: MessageEntities
  actions?: MessageActions
  parseMarkdown?: boolean
}

type Output = {
  updates: Update[]
}

export const editMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)
  const currentUserId = context.currentUserId
  const fullMessage = await MessageModel.getMessage(Number(input.messageId), chatId)
  const normalizedActions = normalizeAndValidateMessageActions(input.actions)
  if (normalizedActions !== undefined) {
    const sender = await UsersModel.getUserById(currentUserId)
    if (!sender?.bot) {
      throw RealtimeRpcError.BadRequest()
    }
  }
  const outgoingText = await processOutgoingText({
    text: input.text,
    entities: input.entities,
    parseMarkdown: input.parseMarkdown,
  })
  const entities = await resolveThreadTitleLinks({
    entities: outgoingText.entities,
    context,
  })

  const { message, update } = await MessageModel.editMessage({
    messageId: Number(input.messageId),
    chatId,
    text: outgoingText.text,
    entities,
    actions: normalizedActions,
  })

  if (!message) {
    Log.shared.error("Message not found")
    throw new Error("Message not found")
  }

  queueMessageThreadLinkMaterialization({
    sourceChatId: chatId,
    sourceMessageGlobalId: message.globalId,
    sourceMessageId: message.messageId,
    sourceMessageFromId: message.fromId,
    sourceMessageRevision: message.rev,
    entities,
  })

  const messageInfo: MessageInfo = {
    message: message,
    photo: fullMessage.photo ?? undefined,
    video: fullMessage.video ?? undefined,
    document: fullMessage.document ?? undefined,
    voice: fullMessage.voice ?? undefined,
  }

  let { selfUpdates } = await pushUpdates({
    inputPeer: input.peer,
    messageInfo,
    currentUserId,
    update,
    actionsOverride: normalizedActions,
  })

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
  actionsOverride,
}: {
  inputPeer: InputPeer
  messageInfo: MessageInfo
  currentUserId: number
  update: UpdateSeqAndDate
  actionsOverride?: MessageActions
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

  let selfUpdates: Update[] = []

  if (updateGroup.type === "dmUsers") {
    updateGroup.userIds.forEach((userId) => {
      const encodingForUserId = userId
      const encodingForInputPeer: InputPeer =
        userId === currentUserId ? inputPeer : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }
      const encodedMessage = Encoders.message({
        ...messageInfo,
        encodingForPeer: { inputPeer: encodingForInputPeer },
        encodingForUserId,
      })
      if (actionsOverride !== undefined) {
        encodedMessage.actions = actionsOverride
      }

      let newMessageUpdate: Update = {
        date: encodeDateStrict(update.date),
        seq: update.seq,

        update: {
          oneofKind: "editMessage",
          editMessage: {
            message: encodedMessage,
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
      const encodedMessage = Encoders.message({
        ...messageInfo,
        encodingForPeer: { inputPeer },
        encodingForUserId: userId,
      })
      if (actionsOverride !== undefined) {
        encodedMessage.actions = actionsOverride
      }

      // New updates
      let editMessageUpdate: Update = {
        date: encodeDateStrict(update.date),
        seq: update.seq,

        update: {
          oneofKind: "editMessage",
          editMessage: {
            message: encodedMessage,
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
