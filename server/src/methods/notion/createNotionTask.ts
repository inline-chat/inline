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

  try {
    // Create Notion page and check message existence in parallel
    const [result, messageExists] = await Promise.all([
      createNotionPage({
        spaceId,
        messageId,
        chatId,
        currentUserId: context.currentUserId,
      }),

      // message exists check
      db
        .select({ count: count() })
        .from(messages)
        .where(eq(messages.globalId, BigInt(messageId)))
        // .where(and(eq(messages.globalId, BigInt(messageId)), eq(messages.chatId, chatId)))
        .then((result) => result[0]!.count > 0),
    ])

    if (!messageExists) {
      Log.shared.error("Message does not exist, cannot create task attachment", { messageId })
      throw new Error("Message does not exist")
    }

    // Encrypt title if it exists
    let encryptedTitle: EncryptedData | null = null
    if (result.taskTitle) {
      encryptedTitle = await encrypt(result.taskTitle)
    }

    // Insert external task and message attachment in parallel
    const [externalTask] = await db
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

    if (!externalTask?.id) {
      throw new Error("Failed to create external task")
    }

    // Create message attachment
    await db.insert(messageAttachments).values({
      messageId: BigInt(messageId),
      externalTaskId: BigInt(externalTask.id),
    })

    // Prepare parallel operations for updates and notifications
    const parallelOperations: Promise<any>[] = []

    // Add message attachment update
    parallelOperations.push(
      messageAttachmentUpdate({
        messageId,
        peerId,
        currentUserId: context.currentUserId,
        externalTask,
        chatId,
        decryptedTitle: result.taskTitle,
      }),
    )

    // Add notifications for other participants about task creation
    if (result.taskTitle) {
      parallelOperations.push(
        (async () => {
          try {
            const updateGroup = await getUpdateGroup(peerId, { currentUserId: context.currentUserId })
            const [senderUser] = await db.select().from(users).where(eq(users.id, context.currentUserId))

            if (senderUser) {
              // Notify other users in the chat (excluding the creator)
              const otherUserIds = updateGroup.userIds.filter((userId) => userId !== context.currentUserId)

              await Promise.all(
                otherUserIds.map((userId) =>
                  Notifications.sendToUser({
                    userId,
                    senderUserId: context.currentUserId,
                    threadId: `chat_${chatId}`,
                    title: `${senderUser.firstName ?? "Someone"} created a Notion task`,
                    body: `"${result.taskTitle}" - A new task has been created from a message`,
                  }),
                ),
              )
            }
          } catch (error) {
            Log.shared.error("Failed to send task creation notifications", { error })
          }
        })(),
      )
    }

    // Execute all parallel operations
    await Promise.allSettled(parallelOperations)

    return { url: result.url, taskTitle: result.taskTitle }
  } catch (error) {
    Log.shared.error("Failed to create Notion task", { error })
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
}: {
  messageId: number
  peerId: TPeerInfo
  currentUserId: number
  externalTask: any
  chatId: number
  decryptedTitle: string | null
}): Promise<void> => {
  try {
    const updateGroup = await getUpdateGroup(peerId, { currentUserId })

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
    if (updateGroup.type === "dmUsers" || updateGroup.type === "threadUsers") {
      updateGroup.userIds.forEach((userId: number) => {
        const update = encodeMessageAttachmentUpdate({
          messageId: BigInt(messageId),
          chatId: BigInt(chatId),
          encodingForUserId: userId,
          encodingForPeer: { inputPeer },
          attachment,
        })
        RealtimeUpdates.pushToUser(userId, [update])
      })
    } else if (updateGroup.type === "spaceUsers") {
      const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
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
