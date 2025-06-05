import { Type, type Static } from "@sinclair/typebox"
import { Log } from "../../utils/log"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { createNotionPage } from "@in/server/modules/notion/agent"
import { db } from "@in/server/db"
import { externalTasks, messageAttachments, messages, users } from "@in/server/db/schema"
import { count, and, eq } from "drizzle-orm"
import { TInputPeerInfo, TPeerInfo } from "../../api-types"
import { getUpdateGroup } from "../../modules/updates"
import { connectionManager } from "../../ws/connections"
import {
  MessageAttachmentExternalTask_Status,
  type Update,
  type MessageAttachment,
  type InputPeer,
} from "@in/protocol/core"
import { RealtimeUpdates } from "../../realtime/message"
import { Notifications } from "../../modules/notifications/notifications"
import { decrypt, encrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { encodeMessageAttachmentUpdate } from "../../realtime/encoders/encodeMessageAttachment"
import { ProtocolConvertors } from "../../types/protocolConvertors"

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

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const { spaceId, messageId, chatId, peerId } = input
  const startTime = Date.now()
  Log.shared.info("🕐 Starting Notion task creation", { ...input, currentUserId: context.currentUserId })

  try {
    // Create Notion page and check message existence in parallel
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
    Log.shared.info("🕐 Completed parallel operations (Notion page + message check)", {
      durationSeconds: ((Date.now() - parallelStart) / 1000).toFixed(3),
    })

    if (!message) {
      Log.shared.error("Message does not exist, cannot create task attachment", { messageId })
      throw new Error("Message does not exist")
    }

    // Encrypt title if it exists (this is fast, no need to parallelize)
    const encryptStart = Date.now()
    let encryptedTitle: EncryptedData | null = null
    if (result.taskTitle) {
      encryptedTitle = await encrypt(result.taskTitle)
    }
    Log.shared.info("🕐 Title encryption completed", {
      durationSeconds: ((Date.now() - encryptStart) / 1000).toFixed(3),
    })

    // Insert external task and get update group info in parallel
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
    Log.shared.info("🕐 Database operations completed (external task + update group)", {
      durationSeconds: ((Date.now() - dbOperationsStart) / 1000).toFixed(3),
    })

    if (!externalTaskResult?.id) {
      throw new Error("Failed to create external task")
    }

    // Create message attachment and get sender user info in parallel
    const attachmentStart = Date.now()
    const [, senderUser] = await Promise.all([
      db.insert(messageAttachments).values({
        messageId: message.globalId,
        externalTaskId: BigInt(externalTaskResult.id),
      }),
      db
        .select()
        .from(users)
        .where(eq(users.id, context.currentUserId))
        .then(([user]) => user),
    ])
    Log.shared.info("🕐 Message attachment and user info completed", {
      durationSeconds: ((Date.now() - attachmentStart) / 1000).toFixed(3),
    })

    // Prepare all parallel operations for updates and notifications
    const updatesStart = Date.now()
    const parallelOperations: Promise<any>[] = []

    // Add message attachment update
    parallelOperations.push(
      messageAttachmentUpdate({
        messageId,
        peerId,
        currentUserId: context.currentUserId,
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
            senderUserId: context.currentUserId,
            threadId: `chat_${chatId}`,
            title: `${senderUser.firstName ?? "Someone"} will do`,
            subtitle: result.taskTitle ?? undefined,
            body: messageText || "A new task has been created from a message",
            isThread: updateGroup.type === "threadUsers",
          }).catch((error) => {
            Log.shared.error("Failed to send task creation notification", { error })
          }),
        )
      }
    }

    // Execute all parallel operations
    await Promise.allSettled(parallelOperations)
    Log.shared.info("🕐 Updates and notifications completed", {
      durationSeconds: ((Date.now() - updatesStart) / 1000).toFixed(3),
    })

    const totalDuration = Date.now() - startTime
    Log.shared.info("🕐 Notion task creation completed successfully", {
      totalDurationSeconds: (totalDuration / 1000).toFixed(3),
      pageId: result.pageId,
      taskTitle: result.taskTitle,
    })

    return { url: result.url, taskTitle: result.taskTitle }
  } catch (error) {
    const totalDuration = Date.now() - startTime
    Log.shared.error("🕐 Failed to create Notion task", {
      error,
      totalDurationSeconds: (totalDuration / 1000).toFixed(3),
    })
    throw error
  }
}

const messageAttachmentUpdate = async ({
  messageId,
  peerId,
  currentUserId,
  externalTask,
  chatId,
  decryptedTitle,
  updateGroup, // Accept updateGroup as parameter to avoid refetching
}: {
  messageId: number
  peerId: TPeerInfo
  currentUserId: number
  externalTask: any
  chatId: number
  decryptedTitle: string | null
  updateGroup?: any // Add this parameter
}): Promise<void> => {
  try {
    // Use passed updateGroup or fetch if not provided (for backward compatibility)
    const finalUpdateGroup = updateGroup || (await getUpdateGroup(peerId, { currentUserId }))

    // Create the MessageAttachment object
    const attachment: MessageAttachment = {
      id: BigInt(externalTask.id),
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
          date: BigInt(Date.now().toString()),
          title: decryptedTitle ?? "",
        },
      },
    }

    // Convert TPeerInfo to InputPeer
    const inputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer(peerId)

    // Send updates to appropriate users
    if (finalUpdateGroup.type === "dmUsers" || finalUpdateGroup.type === "threadUsers") {
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
    Log.shared.error("Failed to update message attachment", { error })
  }
}
