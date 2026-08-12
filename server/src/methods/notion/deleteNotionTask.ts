import { Type, type Static } from "@sinclair/typebox"
import { Log } from "../../utils/log"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { getNotionClient } from "@in/server/modules/notion/notion"
import { db } from "@in/server/db"
import { externalTasks, messageAttachments, messages, chats } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { getUpdateGroup } from "../../modules/updates"
import { RealtimeUpdates } from "../../realtime/message"
import { encodeMessageAttachmentUpdate } from "../../realtime/encoders/encodeMessageAttachment"
import { ProtocolConvertors } from "@in/server/types/protocolConvertors"
import type { MessageAttachment } from "@inline-chat/protocol/core"
import { InlineError } from "../../types/errors"
import { connectionManager } from "../../ws/connections"
import type { TPeerInfo } from "../../api-types"
import { deleteLinearIssue } from "@in/server/libs/linear"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { rejectBotConnectorAccess } from "@in/server/modules/integrations/providerActionContext"
import { Authorize } from "@in/server/utils/authorize"

export const Input = Type.Object({
  externalTaskId: Type.Number(),
  pageId: Type.String(),
  messageId: Type.Number(),
  chatId: Type.Number(),
})

export const Response = Type.Object({
  success: Type.Boolean(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const { externalTaskId, messageId, chatId } = input
  await rejectBotConnectorAccess(context.currentUserId)

  try {
    // Verify task ownership and get required data
    const { externalTask, message, chat, messageAttachmentId } = await verifyAndGetData(
      externalTaskId,
      messageId,
      chatId,
      context.currentUserId,
    )
    const connectorSpaceId = externalTask.connectorSpaceId ?? chat.spaceId
    if (!connectorSpaceId) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }
    await Authorize.spaceMember(connectorSpaceId, context.currentUserId)

    if (externalTask.application === "linear") {
      await deleteFromLinear(
        externalTask.taskId,
        connectorSpaceId,
      )
    } else {
      await deleteFromNotion(
        externalTask.taskId,
        connectorSpaceId,
      )
    }

    await deleteFromDatabase(externalTaskId)

    await sendAttachmentDeletedUpdate(
      message,
      chat,
      externalTaskId,
      messageAttachmentId,
      messageId,
      chatId,
      context.currentUserId,
    )

    Log.shared.info("Successfully deleted attachment and external task", {
      externalTaskId,
      providerTaskId: externalTask.taskId,
      messageId,
      chatId,
    })

    return { success: true }
  } catch (error) {
    Log.shared.error("Failed to delete external task attachment", { error })
    throw error
  }
}

const verifyAndGetData = async (externalTaskId: number, messageId: number, chatId: number, currentUserId: number) => {
  const [bound] = await db
    .select({
      task: externalTasks,
      boundMessage: messages,
      boundChat: chats,
      messageAttachmentId: messageAttachments.id,
    })
    .from(messageAttachments)
    .innerJoin(
      externalTasks,
      eq(messageAttachments.externalTaskId, BigInt(externalTaskId)),
    )
    .innerJoin(messages, eq(messageAttachments.messageId, messages.globalId))
    .innerJoin(chats, eq(messages.chatId, chats.id))
    .where(and(
      eq(externalTasks.id, externalTaskId),
      eq(messages.messageId, messageId),
      eq(chats.id, chatId),
    ))
    .limit(1)

  if (!bound) {
    Log.shared.error("External task attachment did not match message and chat", {
      externalTaskId,
      messageId,
      chatId,
    })
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const {
    task: externalTask,
    boundMessage: message,
    boundChat: chat,
    messageAttachmentId,
  } = bound

  // Verify the user has permission to delete this task
  if (externalTask.assignedUserId !== BigInt(currentUserId)) {
    Log.shared.error("User not authorized to delete this task", {
      externalTaskId,
      assignedUserId: externalTask.assignedUserId,
      currentUserId,
    })
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }

  await AccessGuards.ensureChatAccess(chat, currentUserId)

  return { externalTask, message, chat, messageAttachmentId }
}

const deleteFromLinear = async (issueId: string, connectorSpaceId: number | null) => {
  if (!connectorSpaceId) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const result = await deleteLinearIssue({ spaceId: connectorSpaceId, issueId })
  if (!result.success) {
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

const deleteFromNotion = async (pageId: string, connectorSpaceId: number | null) => {
  if (!connectorSpaceId) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const { client } = await getNotionClient(connectorSpaceId)
  await client.pages.update({
    page_id: pageId,
    archived: true,
  })
  Log.shared.info("Successfully archived Notion page", { pageId })
}

const deleteFromDatabase = async (externalTaskId: number) => {
  await db.transaction(async (tx) => {
    // Delete message attachment
    await tx.delete(messageAttachments).where(eq(messageAttachments.externalTaskId, BigInt(externalTaskId)))

    await tx.delete(externalTasks).where(eq(externalTasks.id, externalTaskId))
  })
}

const sendAttachmentDeletedUpdate = async (
  message: any,
  chat: any,
  externalTaskId: number,
  messageAttachmentId: number | undefined,
  messageId: number,
  chatId: number,
  currentUserId: number,
) => {
  try {
    const peerId: TPeerInfo =
      chat.type === "private"
        ? { userId: chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId } // Get the other user in private chat
        : { threadId: chat.id } // For thread chats, use the chat ID as thread ID

    const updateGroup = await getUpdateGroup(peerId, { currentUserId })

    // Create a delete attachment update using existing UpdateMessageAttachment with null attachment
    const deletionId = messageAttachmentId ?? externalTaskId
    Log.shared.info("Pushing messageAttachment deletion update", {
      currentUserId,
      chatId,
      messageId,
      externalTaskId,
      messageAttachmentId,
      deletionId,
      updateGroupType: updateGroup.type,
    })
    const deletedAttachment: MessageAttachment = {
      id: BigInt(deletionId),
      attachment: { oneofKind: undefined },
    }

    const inputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer(peerId)

    // Send updates to appropriate users - following the same pattern as createNotionTask
    if (updateGroup.type === "dmUsers") {
      const currentUserInputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer({ userId: currentUserId })
      updateGroup.userIds.forEach((userId: number) => {
        const encodingForInputPeer = userId === currentUserId ? inputPeer : currentUserInputPeer
        const update = encodeMessageAttachmentUpdate({
          messageId: BigInt(messageId),
          chatId: BigInt(chatId),
          encodingForUserId: userId,
          encodingForPeer: { inputPeer: encodingForInputPeer },
          attachment: deletedAttachment,
        })
        RealtimeUpdates.pushToUser(userId, [update])
      })
    } else if (updateGroup.type === "threadUsers") {
      updateGroup.userIds.forEach((userId: number) => {
        const update = encodeMessageAttachmentUpdate({
          messageId: BigInt(messageId),
          chatId: BigInt(chatId),
          encodingForUserId: userId,
          encodingForPeer: { inputPeer },
          attachment: deletedAttachment,
        })
        RealtimeUpdates.pushToUser(userId, [update])
      })
    } else if (updateGroup.type === "spaceUsers") {
      const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
      userIds.forEach((userId: number) => {
        const update = encodeMessageAttachmentUpdate({
          messageId: BigInt(messageId),
          chatId: BigInt(chatId),
          encodingForUserId: userId,
          encodingForPeer: { inputPeer },
          attachment: deletedAttachment,
        })
        RealtimeUpdates.pushToUser(userId, [update])
      })
    }
  } catch (updateError) {
    Log.shared.error("Failed to send attachment deletion update", { updateError })
  }
}
