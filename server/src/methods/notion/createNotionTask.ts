import { Type, type Static } from "@sinclair/typebox"
import { getDatabases } from "../../modules/notion/notion"
import { Log } from "../../utils/log"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { createNotionPage } from "@in/server/modules/notion/agent"
import { db } from "@in/server/db"
import { externalTasks, messageAttachments, messages, users } from "@in/server/db/schema"
import { count, and, eq } from "drizzle-orm"
import { TInputPeerInfo, TPeerInfo } from "../../api-types"
import { getUpdateGroup } from "../../modules/updates"
import { connectionManager } from "../../ws/connections"
import { MessageAttachmentExternalTask_Status, type Update } from "@in/protocol/core"
import { RealtimeUpdates } from "../../realtime/message"
import { Notifications } from "../../modules/notifications/notifications"
import { decrypt, encrypt } from "@in/server/modules/encryption/encryption"

export const Input = Type.Object({
  spaceId: Type.Number(),
  messagesIds: Type.Array(Type.Number()),
  messageId: Type.Number(),
  chatId: Type.Number(),
  peerId: TInputPeerInfo,
  fromId: Type.Number(),
})

export const Response = Type.Object({
  url: Type.String(),
  taskTitle: Type.String(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const { spaceId, messagesIds, messageId, chatId, peerId, fromId } = input

  try {
    const result = await createNotionPage({
      spaceId,
      messagesIds,
      messageId,
      chatId,
      currentUserId: context.currentUserId,
    })

    const encryptedTitle = await encrypt(result.taskTitle)

    const [externalTask] = await db
      .insert(externalTasks)
      .values({
        application: "notion",
        taskId: result.pageId,
        status: "todo",
        assignedUserId: BigInt(context.currentUserId),
        title: encryptedTitle.encrypted,
        titleIv: encryptedTitle.iv,
        titleTag: encryptedTitle.authTag,
        url: result.url,
        date: new Date(),
      })
      .returning()

    if (externalTask?.id) {
      try {
        const messageExists = await db
          .select({ count: count() })
          .from(messages)
          .where(and(eq(messages.messageId, messageId), eq(messages.chatId, chatId)))
          .then((result) => result[0]!.count > 0)

        if (messageExists) {
          await db
            .insert(messageAttachments)
            .values({
              messageId: BigInt(messageId),
              externalTaskId: BigInt(externalTask.id),
            })
            .returning()
        } else {
          Log.shared.error("Message does not exist, skipping message attachment creation", { messageId })
        }
      } catch (error) {
        Log.shared.error("Failed to create message attachment", { error, messageId })
      }
    }

    if (externalTask) {
      try {
        await messageAttachmentUpdate({
          messageId,
          peerId,
          currentUserId: context.currentUserId,
          externalTask,
          chatId,
        })
      } catch (error) {
        Log.shared.error("Failed to update message attachment", { error })
      }
    }

    let [senderUser] = await db.select().from(users).where(eq(users.id, fromId))

    if (senderUser && fromId !== context.currentUserId) {
      sendNotificationToUser({
        userId: fromId,
        userName: senderUser.firstName ?? "User",
        currentUserId: context.currentUserId,
        chatId,
      })
    }

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
}: {
  messageId: number
  peerId: TPeerInfo
  currentUserId: number
  externalTask: any
  chatId: number
}): Promise<void> => {
  try {
    const messageExists = await db
      .select({ count: count() })
      .from(messages)
      .where(and(eq(messages.messageId, messageId), eq(messages.chatId, chatId)))
      .then((result) => result[0]!.count > 0)

    if (!messageExists) {
      Log.shared.error("Message does not exist, skipping message attachment update", { messageId })
      return
    }

    // decrypt title
    if (!externalTask.titleTag || !externalTask.title || !externalTask.titleIv) {
      Log.shared.error("Missing title tag, title, or title iv", { externalTask })
      return
    }

    const decryptedTitle = await decrypt({
      authTag: externalTask.titleTag,
      encrypted: externalTask.title,
      iv: externalTask.titleIv,
    })

    const updateGroup = await getUpdateGroup(peerId, { currentUserId })

    if (updateGroup.type === "dmUsers" || updateGroup.type === "threadUsers") {
      updateGroup.userIds.forEach((userId: number) => {
        let messageAttachmentUpdate: Update = {
          update: {
            oneofKind: "messageAttachment",
            messageAttachment: {
              messageId: BigInt(messageId),
              chatId: BigInt(chatId),
              attachment: {
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
                    title: decryptedTitle,
                  },
                },
              },
            },
          },
        }
        RealtimeUpdates.pushToUser(userId, [messageAttachmentUpdate])
      })
    } else if (updateGroup.type === "spaceUsers") {
      const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)

      userIds.forEach((userId) => {
        let messageAttachmentUpdate: Update = {
          update: {
            oneofKind: "messageAttachment",
            messageAttachment: {
              messageId: BigInt(messageId),
              chatId: BigInt(chatId),
              attachment: {
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
                    title: decryptedTitle,
                  },
                },
              },
            },
          },
        }

        RealtimeUpdates.pushToUser(userId, [messageAttachmentUpdate])
      })
    }
  } catch (error) {
    Log.shared.error("Failed to update message attachment", { error })
  }
}

/** Send push notifications for this message */
async function sendNotificationToUser({
  userId,
  userName,
  currentUserId,
  chatId,
}: {
  userId: number
  userName: string
  currentUserId: number
  chatId: number
}) {
  const title = `${userName} created a Notion task`
  let body = `A new task has been created by ${userName} in Notion from your message`

  Notifications.sendToUser({
    userId,
    senderUserId: currentUserId,
    threadId: `chat_${chatId}`,
    title,
    body,
  })
}
