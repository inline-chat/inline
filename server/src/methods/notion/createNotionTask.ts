import { Type, type Static } from "@sinclair/typebox"
import { Log, LogLevel } from "../../utils/log"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { createNotionPage } from "@in/server/modules/notion/agent"
import { db } from "@in/server/db"
import { externalTasks, messageAttachments, messages, users } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { TInputPeerInfo, TPeerInfo } from "../../api-types"
import { getUpdateGroup } from "../../modules/updates"
import { connectionManager } from "../../ws/connections"
import {
  MessageAttachmentExternalTask_Status,
  type MessageAttachment,
} from "@inline-chat/protocol/core"
import { RealtimeUpdates } from "../../realtime/message"
import { Notifications } from "../../modules/notifications/notifications"
import { encrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { encodeMessageAttachmentUpdate } from "../../realtime/encoders/encodeMessageAttachment"
import { ProtocolConvertors } from "@in/server/types/protocolConvertors"
import { isDev } from "@in/server/env"
import { InlineError } from "@in/server/types/errors"

export const Input = Type.Object({
  spaceId: Type.Number(),
  messageId: Type.Number(),
  chatId: Type.Number(),
  peerId: TInputPeerInfo,
})

export const Response = Type.Object({
  url: Type.String(),
  taskTitle: Type.Union([Type.String(), Type.Null()]),
})

const logDevTelemetry = (message: string, metadata: Record<string, unknown>) => {
  if (isDev) {
    Log.shared.info(message, metadata)
  }
}

const taskTelemetryLog = new Log("NotionTaskCreate", LogLevel.INFO)

const logProdTelemetry = (message: string, metadata: Record<string, unknown>) => {
  if (!isDev) {
    taskTelemetryLog.info(message, metadata)
  }
}

const errorTelemetry = (error: unknown) => ({
  errorName: error instanceof Error ? error.name : "UnknownError",
  errorMessage: error instanceof Error ? error.message : String(error),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const { spaceId, messageId, chatId, peerId } = input
  const startTime = Date.now()
  let stage = "start"
  const telemetry = {
    spaceId,
    chatId,
    messageId,
    peerType: "userId" in peerId ? "dm" : "thread",
  }
  const devTelemetry = { ...telemetry, currentUserId: context.currentUserId }

  logProdTelemetry("Notion task creation started", telemetry)
  logDevTelemetry("Starting Notion task creation", devTelemetry)

  try {
    // Create Notion page and check message existence in parallel
    stage = "create_page_and_load_message"
    const parallelStart = Date.now()
    const [result, message] = await Promise.all([
      createNotionPage({
        spaceId,
        messageId,
        chatId,
        currentUserId: context.currentUserId,
      }),
      db
        .select()
        .from(messages)
        .where(and(eq(messages.messageId, messageId), eq(messages.chatId, chatId)))
        .then((result) => result[0]),
    ])
    logDevTelemetry("Notion task context loaded", {
      ...devTelemetry,
      durationMs: Date.now() - parallelStart,
    })

    if (!message) {
      Log.shared.error("Message does not exist, cannot create task attachment", devTelemetry)
      throw new Error("Message does not exist")
    }

    // Encrypt title if it exists (this is fast, no need to parallelize)
    stage = "encrypt_task_title"
    const encryptStart = Date.now()
    let encryptedTitle: EncryptedData | null = null
    if (result.taskTitle) {
      encryptedTitle = await encrypt(result.taskTitle)
    }
    logDevTelemetry("Notion task title encrypted", {
      ...devTelemetry,
      durationMs: Date.now() - encryptStart,
      hasTitle: Boolean(result.taskTitle),
    })

    // Insert external task and get update group info in parallel
    stage = "write_task_and_update_group"
    const dbOperationsStart = Date.now()
    const [externalTaskResult, updateGroup] = await Promise.all([
      db
        .insert(externalTasks)
        .values({
          application: "notion",
          taskId: result.pageId,
          status: "todo",
          assignedUserId: BigInt(context.currentUserId),
          title: encryptedTitle?.encrypted ?? null,
          titleIv: encryptedTitle?.iv ?? null,
          titleTag: encryptedTitle?.authTag ?? null,
          url: result.url,
          date: new Date(),
        })
        .returning()
        .then(([task]) => task),
      getUpdateGroup(peerId, { currentUserId: context.currentUserId }),
    ])
    logDevTelemetry("Notion task database writes completed", {
      ...devTelemetry,
      durationMs: Date.now() - dbOperationsStart,
      hasExternalTask: Boolean(externalTaskResult?.id),
      updateGroupType: updateGroup.type,
    })

    if (!externalTaskResult?.id) {
      throw new Error("Failed to create external task")
    }

    // Create message attachment and get sender user info in parallel
    stage = "write_message_attachment_and_load_sender"
    const attachmentStart = Date.now()
    const [messageAttachmentRow, senderUser] = await Promise.all([
      db
        .insert(messageAttachments)
        .values({
          messageId: message.globalId,
          externalTaskId: BigInt(externalTaskResult.id),
        })
        .returning()
        .then(([row]) => row),
      db
        .select()
        .from(users)
        .where(eq(users.id, context.currentUserId))
        .then(([user]) => user),
    ])
    logDevTelemetry("Notion attachment write completed", {
      ...devTelemetry,
      durationMs: Date.now() - attachmentStart,
      hasAttachment: Boolean(messageAttachmentRow?.id),
    })

    if (!messageAttachmentRow?.id) {
      throw new Error("Failed to create message attachment")
    }

    // Prepare all parallel operations for updates and notifications
    stage = "push_updates_and_notifications"
    const updatesStart = Date.now()
    const parallelOperations: Promise<unknown>[] = []

    // Add message attachment update
    parallelOperations.push(
      messageAttachmentUpdate({
        messageId,
        peerId,
        currentUserId: context.currentUserId,
        messageAttachmentId: BigInt(messageAttachmentRow.id),
        externalTask: externalTaskResult,
        chatId,
        decryptedTitle: result.taskTitle,
        updateGroup, // Pass the already fetched updateGroup
      }),
    )

    if (result.taskTitle && senderUser) {
      // Notify only the message sender
      const messageSenderId = message.fromId

      if (messageSenderId !== context.currentUserId) {
        // Decrypt message text for notification description
        let messageText = message.text || ""
        if (message.textEncrypted && message.textIv && message.textTag) {
          messageText = decryptMessage({
            encrypted: message.textEncrypted,
            iv: message.textIv,
            authTag: message.textTag,
          })
        }

        parallelOperations.push(
          Notifications.sendToUser({
            userId: messageSenderId,
            payload: {
              kind: "alert",
              senderUserId: context.currentUserId,
              threadId: `chat_${chatId}`,
              title: `${senderUser.firstName ?? "Someone"} will do`,
              subtitle: result.taskTitle ?? undefined,
              body: messageText || "A new task has been created from a message",
              isThread: updateGroup.type === "threadUsers",
            },
          }).catch((error) => {
            Log.shared.error("Failed to send task creation notification", error, devTelemetry)
          }),
        )
      }
    }

    // Execute all parallel operations
    await Promise.allSettled(parallelOperations)
    logDevTelemetry("Notion updates and notifications completed", {
      ...devTelemetry,
      durationMs: Date.now() - updatesStart,
    })

    const totalDuration = Date.now() - startTime
    logProdTelemetry("Notion task creation completed", {
      ...telemetry,
      totalDurationMs: totalDuration,
      hasTaskTitle: Boolean(result.taskTitle),
    })
    logDevTelemetry("Notion task creation completed", {
      ...devTelemetry,
      totalDurationMs: totalDuration,
      hasPageId: Boolean(result.pageId),
      hasTaskTitle: Boolean(result.taskTitle),
    })

    return { url: result.url, taskTitle: result.taskTitle }
  } catch (error) {
    const totalDuration = Date.now() - startTime
    logProdTelemetry("Notion task creation failed", {
      ...telemetry,
      stage,
      totalDurationMs: totalDuration,
    })
    const errorMeta = errorTelemetry(error)
    Log.shared.error("Failed to create Notion task", error, {
      ...devTelemetry,
      stage,
      totalDurationMs: totalDuration,
      ...errorMeta,
    })

    if (error instanceof InlineError) {
      throw error
    }

    const internalError = new InlineError(InlineError.ApiError.INTERNAL)
    internalError.description = `Failed to create Notion task (${stage}): ${errorMeta.errorMessage}`
    throw internalError
  }
}

const messageAttachmentUpdate = async ({
  messageId,
  peerId,
  currentUserId,
  messageAttachmentId,
  externalTask,
  chatId,
  decryptedTitle,
  updateGroup, // Accept updateGroup as parameter to avoid refetching
}: {
  messageId: number
  peerId: TPeerInfo
  currentUserId: number
  messageAttachmentId: bigint
  externalTask: any
  chatId: number
  decryptedTitle: string | null
  updateGroup?: any // Add this parameter
}): Promise<void> => {
  try {
    // Use passed updateGroup or fetch if not provided (for backward compatibility)
    const finalUpdateGroup = updateGroup || (await getUpdateGroup(peerId, { currentUserId }))
    logDevTelemetry("Pushing messageAttachment update for Notion external task", {
      currentUserId,
      chatId,
      messageId,
      updateGroupType: finalUpdateGroup.type,
      recipientCount:
        finalUpdateGroup.type === "spaceUsers"
          ? connectionManager.getSpaceUserIds(finalUpdateGroup.spaceId).length
          : Array.isArray(finalUpdateGroup.userIds)
          ? finalUpdateGroup.userIds.length
          : undefined,
    })

    // Create the MessageAttachment object
    const attachment: MessageAttachment = {
      id: messageAttachmentId,
      attachment: {
        oneofKind: "externalTask",
        externalTask: {
          id: BigInt(externalTask.id),
          application: "notion",
          taskId: externalTask.taskId,
          status: MessageAttachmentExternalTask_Status.TODO,
          assignedUserId: BigInt(currentUserId),
          number: "",
          url: externalTask.url ?? "",
          date: BigInt(Math.round(Date.now() / 1000)),
          title: decryptedTitle ?? "",
        },
      },
    }

    // Convert TPeerInfo to InputPeer
    const inputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer(peerId)

    // Send updates to appropriate users
    if (finalUpdateGroup.type === "dmUsers") {
      const currentUserInputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer({ userId: currentUserId })
      finalUpdateGroup.userIds.forEach((userId: number) => {
        const encodingForInputPeer = userId === currentUserId ? inputPeer : currentUserInputPeer
        const update = encodeMessageAttachmentUpdate({
          messageId: BigInt(messageId),
          chatId: BigInt(chatId),
          encodingForUserId: userId,
          encodingForPeer: { inputPeer: encodingForInputPeer },
          attachment,
        })
        RealtimeUpdates.pushToUser(userId, [update])
      })
    } else if (finalUpdateGroup.type === "threadUsers") {
      finalUpdateGroup.userIds.forEach((userId: number) => {
        const update = encodeMessageAttachmentUpdate({
          messageId: BigInt(messageId),
          chatId: BigInt(chatId),
          encodingForUserId: userId,
          encodingForPeer: { inputPeer },
          attachment,
        })
        RealtimeUpdates.pushToUser(userId, [update])
      })
    } else if (finalUpdateGroup.type === "spaceUsers") {
      const userIds = connectionManager.getSpaceUserIds(finalUpdateGroup.spaceId)
      userIds.forEach((userId) => {
        const update = encodeMessageAttachmentUpdate({
          messageId: BigInt(messageId),
          chatId: BigInt(chatId),
          encodingForUserId: userId,
          encodingForPeer: { inputPeer },
          attachment,
        })
        RealtimeUpdates.pushToUser(userId, [update])
      })
    }
  } catch (error) {
    Log.shared.error("Failed to update message attachment for Notion task", error, {
      currentUserId,
      chatId,
      messageId,
      ...errorTelemetry(error),
    })
  }
}
