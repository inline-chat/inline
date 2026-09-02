import { MessageEntity_Type, type InputPeer, type MessageActions, type MessageEntities, type Update } from "@inline-chat/protocol/core"
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
import { prepareBlockContent, type PreparedBlockContent } from "@in/server/modules/message/blockContentStorage"
import { normalizeAndValidateMessageActions } from "@in/server/modules/message/messageActions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { queueMessageThreadLinkMaterialization } from "@in/server/modules/threadGraph"
import { resolveThreadTitleLinks } from "@in/server/modules/message/resolveThreadTitleLinks"
import { resolveBotCommandTargets } from "@in/server/modules/message/resolveBotCommandTargets"
import { validateGroupMentions } from "@in/server/modules/message/resolveGroupMentions"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"
import { isImportedAgentMessage } from "@in/server/modules/agentSessions/service"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  getMessageThreadProjectionsMap,
  isSubthreadParentMessage,
  type MessageThreadProjection,
} from "@in/server/modules/subthreads"

type Input = {
  messageId: bigint
  peer: InputPeer
  /** Omit to preserve text, entities, and structural block content. */
  text?: string
  entities?: MessageEntities
  actions?: MessageActions
  parseMarkdown?: boolean
}

type Output = {
  updates: Update[]
}

export const editMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peer, context)
  const chatId = chat.id
  const currentUserId = context.currentUserId
  await AccessGuards.ensureChatAccess(chat, currentUserId)
  const fullMessage = await MessageModel.getMessage(Number(input.messageId), chatId)
  if (fullMessage && await isSubthreadParentMessage(fullMessage.globalId)) {
    throw RealtimeRpcError.BadRequest()
  }
  if (await isImportedAgentMessage(chatId, Number(input.messageId))) {
    throw RealtimeRpcError.AgentSessionMessageImmutable()
  }
  if (!fullMessage || fullMessage.fromId !== currentUserId) {
    Log.shared.warn("editMessage blocked: message author mismatch", {
      chatId,
      messageId: Number(input.messageId),
      fromId: fullMessage?.fromId,
      currentUserId,
    })
    throw RealtimeRpcError.BadRequest()
  }
  const normalizedActions = normalizeAndValidateMessageActions(input.actions)
  if (normalizedActions !== undefined) {
    const sender = await UsersModel.getUserById(currentUserId)
    if (!sender?.bot) {
      throw RealtimeRpcError.BadRequest()
    }
  }
  const outgoingText = input.text === undefined
    ? {
        text: fullMessage.text ?? "",
        entities: fullMessage.entities ?? undefined,
        blockContent: undefined,
        blockImageSources: undefined,
      }
    : await processOutgoingText({
        text: input.text,
        entities: input.entities,
        parseMarkdown: input.parseMarkdown,
      })
  let entities = outgoingText.entities
  if (input.text !== undefined) {
    entities = await resolveThreadTitleLinks({ entities, context })
    entities = await resolveBotCommandTargets({
      text: outgoingText.text,
      entities,
      chat,
      currentUserId,
    })
    entities = await validateGroupMentions({ text: outgoingText.text, entities, chat, currentUserId })
  }

  let preparedBlockContent: PreparedBlockContent | null | undefined =
    input.text === undefined ? undefined : null
  if (input.text !== undefined && outgoingText.blockContent) {
    try {
      preparedBlockContent = prepareBlockContent({
        text: outgoingText.text,
        entities,
        parsed: {
          blockContent: outgoingText.blockContent,
          imageSources: outgoingText.blockImageSources ?? [],
        },
      }) ?? null
    } catch (error) {
      Log.shared.error("rich content preparation failed; editing the plain projection", {
        chatId,
        currentUserId,
        errorType: error instanceof Error ? error.name : "UnknownError",
      })
    }
  }

  const { message, update } = await MessageModel.editMessage({
    messageId: Number(input.messageId),
    chatId,
    text: outgoingText.text,
    entities,
    actions: normalizedActions,
    blockContent: preparedBlockContent,
    suppressEditDate: context.isBot === true,
  })

  if (!message) {
    Log.shared.error("Message not found")
    throw new Error("Message not found")
  }

  if (input.text !== undefined && (hasThreadEntity(fullMessage.entities) || hasThreadEntity(entities))) {
    queueMessageThreadLinkMaterialization({
      sourceChatId: chatId,
      sourceMessageGlobalId: message.globalId,
      sourceMessageId: message.messageId,
      sourceMessageFromId: message.fromId,
      sourceMessageRevision: message.rev,
      entities,
    })
  }

  const messageInfo: MessageInfo = {
    message: {
      ...message,
      blockContent:
        message.blockContent === undefined
          ? fullMessage.blockContent
          : message.blockContent,
    },
    photo: fullMessage.photo ?? undefined,
    video: fullMessage.video ?? undefined,
    document: fullMessage.document ?? undefined,
    voice: fullMessage.voice ?? undefined,
  }
  const threadProjection = (
    await getMessageThreadProjectionsMap({
      parentChatId: chatId,
      parentMessageIds: [message.messageId],
      userId: currentUserId,
    })
  ).get(message.messageId)

  let { selfUpdates } = await pushUpdates({
    inputPeer: input.peer,
    messageInfo,
    currentUserId,
    update,
    actionsOverride: normalizedActions,
    threadProjection,
  })

  BotUpdateProjector.messageEdited({
    chat,
    messageId: Number(input.messageId),
  })

  return { updates: selfUpdates }
}

type EncodeMessageInput = Parameters<typeof Encoders.message>[0]
type MessageInfo = Omit<EncodeMessageInput, "encodingForUserId" | "encodingForPeer">

function hasThreadEntity(entities: MessageEntities | null | undefined): boolean {
  return entities?.entities.some((entity) => entity.type === MessageEntity_Type.THREAD) ?? false
}

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
  threadProjection,
}: {
  inputPeer: InputPeer
  messageInfo: MessageInfo
  currentUserId: number
  update: UpdateSeqAndDate
  actionsOverride?: MessageActions
  threadProjection?: MessageThreadProjection
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

  const projectionForUser = async (userId: number): Promise<MessageThreadProjection | undefined> => {
    if (!threadProjection || userId === currentUserId) {
      return threadProjection
    }
    return (
      await getMessageThreadProjectionsMap({
        parentChatId: messageInfo.message.chatId,
        parentMessageIds: [messageInfo.message.messageId],
        userId,
      })
    ).get(messageInfo.message.messageId)
  }

  let selfUpdates: Update[] = []

  if (updateGroup.type === "dmUsers") {
    for (const userId of updateGroup.userIds) {
      const encodingForUserId = userId
      const encodingForInputPeer: InputPeer =
        userId === currentUserId ? inputPeer : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }
      const projection = await projectionForUser(userId)
      const encodedMessage = Encoders.message({
        ...messageInfo,
        encodingForPeer: { inputPeer: encodingForInputPeer },
        encodingForUserId,
        replies: projection?.replies,
        subthread: projection?.subthread,
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
    }
  } else if (updateGroup.type === "threadUsers") {
    for (const userId of updateGroup.userIds) {
      const projection = await projectionForUser(userId)
      const encodedMessage = Encoders.message({
        ...messageInfo,
        encodingForPeer: { inputPeer },
        encodingForUserId: userId,
        replies: projection?.replies,
        subthread: projection?.subthread,
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
    }
  }

  return { selfUpdates, updateGroup }
}
