import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { ModelError } from "@in/server/db/models/_errors"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroupFromInputPeer } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { Notifications } from "@in/server/modules/notifications/notifications"
import {
  emitMessageSubthreadUpdateIfNeeded,
  getSubthreadParentMessageRef,
  isLinkedSubthread,
  isReplyThread,
  queueSubthreadParentUpdate,
} from "@in/server/modules/subthreads"
import { pushChatMetadataUpdates } from "@in/server/modules/chatMetadataUpdatePush"
import { deleteBacklinkMessages, getBacklinkMessagesForSourceMessages } from "@in/server/modules/threadGraph"
import { db } from "@in/server/db"
import { members, messages, type DbChat } from "@in/server/db/schema"
import { and, eq, inArray } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"
import { hasImportedAgentMessages } from "@in/server/modules/agentSessions/service"

type Input = {
  messageIds: bigint[]
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const deleteMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  return deleteMessageWithOptions(input, context)
}

export async function deleteSubthreadParentPlacement(
  childChatId: number,
  context: FunctionContext,
): Promise<void> {
  const parentMessage = await getSubthreadParentMessageRef(childChatId)
  if (!parentMessage) {
    return
  }

  try {
    await deleteMessageWithOptions({
      peer: {
        type: {
          oneofKind: "chat",
          chat: { chatId: BigInt(parentMessage.parentChatId) },
        },
      },
      messageIds: [BigInt(parentMessage.parentMessageId)],
    }, context, { trustedPlacementCleanup: true })
  } catch (error) {
    if (error instanceof ModelError && error.code === ModelError.Codes.MESSAGE_INVALID) {
      return
    }
    throw error
  }
}

async function deleteMessageWithOptions(
  input: Input,
  context: FunctionContext,
  options: { trustedPlacementCleanup?: boolean } = {},
): Promise<Output> {
  const chat = await ChatModel.getChatFromInputPeer(input.peer, context)
  if (!options.trustedPlacementCleanup) {
    await AccessGuards.ensureChatAccess(chat, context.currentUserId)
  }

  const numericMessageIds = input.messageIds
    .map(Number)
    .filter((id) => Number.isSafeInteger(id) && id > 0)
  if (await hasImportedAgentMessages(chat.id, numericMessageIds)) {
    throw RealtimeRpcError.AgentSessionMessageImmutable()
  }

  if (!options.trustedPlacementCleanup) {
    await ensureDeleteAllowed({
      chat,
      messageIds: input.messageIds,
      currentUserId: context.currentUserId,
    })
  }

  const backlinkMessages = options.trustedPlacementCleanup
    ? []
    : await getBacklinkMessagesForSourceMessages({
        chatId: chat.id,
        messageIds: input.messageIds,
      })

  let { update, metadataChatUpdates } = await MessageModel.deleteMessages(input.messageIds, chat.id)
  if (!options.trustedPlacementCleanup) {
    BotUpdateProjector.messageRoutesDeleted({ chatId: chat.id, messageIds: input.messageIds })
  }
  const backlinkSelfUpdates = await deleteBacklinkMessages(backlinkMessages, {
    currentUserId: context.currentUserId,
  })

  const { selfUpdates, updateGroup } = await pushUpdates({
    inputPeer: input.peer,
    messageIds: input.messageIds,
    currentUserId: context.currentUserId,
    update,
  })

  const { selfUpdates: metadataSelfUpdates } = await pushChatMetadataUpdates({
    currentUserId: context.currentUserId,
    chatUpdates: metadataChatUpdates,
  })

  if (isReplyThread(chat)) {
    await emitMessageSubthreadUpdateIfNeeded({
      chatId: chat.id,
      currentUserId: context.currentUserId,
    })
  } else if (isLinkedSubthread(chat)) {
    queueSubthreadParentUpdate({
      chatId: chat.id,
      currentUserId: context.currentUserId,
      reason: "message deletion",
    })
  }

  if (!options.trustedPlacementCleanup) {
    await Promise.all(
      updateGroup.userIds.map(async (userId) => {
        await Notifications.sendToUser({
          userId,
          payload: {
            kind: "message_deleted",
            threadId: `chat_${chat.id}`,
            messageIds: input.messageIds.map((id) => id.toString()),
          },
        })
      }),
    )
  }

  return { updates: [...selfUpdates, ...metadataSelfUpdates, ...backlinkSelfUpdates] }
}

async function ensureDeleteAllowed(input: {
  chat: DbChat
  messageIds: bigint[]
  currentUserId: number
}): Promise<void> {
  if (input.chat.spaceId === null) {
    return
  }

  const messageIds = input.messageIds
    .map((id) => Number(id))
    .filter((id) => Number.isSafeInteger(id) && id > 0)

  if (messageIds.length === 0) {
    return
  }

  const rows = await db
    .select({
      messageId: messages.messageId,
      fromId: messages.fromId,
    })
    .from(messages)
    .where(and(eq(messages.chatId, input.chat.id), inArray(messages.messageId, messageIds)))

  if (rows.every((message) => message.fromId === input.currentUserId)) {
    return
  }

  const [member] = await db
    .select({ role: members.role })
    .from(members)
    .where(and(eq(members.spaceId, input.chat.spaceId), eq(members.userId, input.currentUserId)))
    .limit(1)

  if (member?.role === "admin" || member?.role === "owner") {
    return
  }

  throw RealtimeRpcError.SpaceAdminRequired()
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
