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
import { ProtocolConvertors } from "../../types/protocolConvertors"
import type { MessageAttachment } from "@in/protocol/core"
import { InlineError } from "../../types/errors"
import { connectionManager } from "../../ws/connections"
import type { TPeerInfo } from "../../api-types"

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
  const { externalTaskId, pageId, messageId, chatId } = input

  try {
    // Verify task ownership and get required data
    const { externalTask, message, chat } = await verifyAndGetData(
      externalTaskId,
      messageId,
      chatId,
      context.currentUserId,
    )

    await deleteFromNotion(pageId, chat)

    await deleteFromDatabase(externalTaskId, messageId)

    await sendAttachmentDeletedUpdate(message, chat, externalTaskId, messageId, chatId, context.currentUserId)

    Log.shared.info("Successfully deleted attachment and external task", {
      externalTaskId,
      pageId,
      messageId,
      chatId,
    })

    return { success: true }
  } catch (error) {
    Log.shared.error("Failed to delete Notion task", { error })
    throw error
  }
}

const verifyAndGetData = async (externalTaskId: number, messageId: number, chatId: number, currentUserId: number) => {
  // Get the external task to verify ownership
  const [externalTask] = await db.select().from(externalTasks).where(eq(externalTasks.id, externalTaskId))

  if (!externalTask) {
    Log.shared.error("External task not found", { externalTaskId })
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  // Verify the user has permission to delete this task
  if (externalTask.assignedUserId !== BigInt(currentUserId)) {
    Log.shared.error("User not authorized to delete this task", {
      externalTaskId,
      assignedUserId: externalTask.assignedUserId,
      currentUserId,
    })
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }

  // Get the message
  const [message] = await db
    .select()
    .from(messages)
    .where(and(eq(messages.messageId, messageId), eq(messages.chatId, chatId)))

  if (!message) {
    Log.shared.error("Message not found", { messageId, chatId })
    throw new InlineError(InlineError.ApiError.MSG_ID_INVALID)
  }

  // Get chat info
  const [chat] = await db.select().from(chats).where(eq(chats.id, chatId))

  if (!chat) {
    Log.shared.error("Chat not found", { chatId })
    throw new InlineError(InlineError.ApiError.CHAT_ID_INVALID)
  }

  return { externalTask, message, chat }
}

const deleteFromNotion = async (pageId: string, chat: any) => {
  try {
    if (chat?.spaceId) {
      const notion = await getNotionClient(Number(chat.spaceId))

      // Archive the page in Notion (Notion doesn't allow permanent deletion via API)
      await notion.pages.update({
        page_id: pageId,
        archived: true,
      })

      Log.shared.info("Successfully archived Notion page", { pageId })
    } else {
      Log.shared.warn("No space ID found for chat, skipping Notion deletion", { chatId: chat.id })
    }
  } catch (notionError) {
    Log.shared.error("Failed to archive Notion page", {
      pageId,
      error: notionError instanceof Error ? notionError.message : String(notionError),
    })
  }
}

const deleteFromDatabase = async (externalTaskId: number, messageId: number) => {
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
    const deletedAttachment: MessageAttachment = {
      id: BigInt(externalTaskId),
      attachment: { oneofKind: undefined },
    }

    const inputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer(peerId)

    // Send updates to appropriate users - following the same pattern as createNotionTask
    if (updateGroup.type === "dmUsers") {
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
