import { Optional, Type, type Static } from "@sinclair/typebox"
import { eq, count } from "drizzle-orm"
import OpenAI from "openai"
import { spaces, users, messages } from "../db/schema"
import { db } from "../db"
import { z } from "zod"
import {
  createIssue,
  generateIssueLink,
  getLinearIssueLabels,
  getLinearIssueStatuses,
  getLinearOrg,
  getLinearTeams,
  getLinearUser,
  getLinearUsers,
} from "@in/server/libs/linear"
import { openaiClient } from "../libs/openAI"
import { Log } from "../utils/log"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import { anthropic } from "../libs/anthropic"
import {
  messageAttachments,
  externalTasks,
  type DbNewMessageAttachment,
  type DbExternalTask,
} from "../db/schema/attachments"
import { decrypt, encrypt } from "../modules/encryption/encryption"
import { TInputPeerInfo, TPeerInfo, type TUpdateInfo } from "../api-types"
import { getUpdateGroup } from "../modules/updates"
import { connectionManager } from "../ws/connections"
import { createMessage, ServerMessageKind } from "../ws/protocol"
import { MessageAttachmentExternalTask_Status, type Update } from "@in/protocol/core"
import { RealtimeUpdates } from "../realtime/message"
import { examples, prompt } from "../libs/linear/prompt"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  text: Type.String(),
  messageId: Type.Number(),
  peerId: TInputPeerInfo,
})

export const Response = Type.Object({
  link: Optional(Type.String()),
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  let { text, messageId, peerId } = input

  const [labels, [user], linearUsers] = await Promise.all([
    getLinearIssueLabels({ userId: currentUserId }),
    db.select().from(users).where(eq(users.id, currentUserId)),
    getLinearUsers({ userId: currentUserId }),
  ])

  const assigneeId = linearUsers.users.find((u: any) => u.email === user?.email)?.id

  const msg = await anthropic.messages.create({
    model: "claude-3-7-sonnet-20250219",
    max_tokens: 20000,
    temperature: 1,
    messages: [
      {
        role: "user",
        content: [
          {
            type: "text",
            text: examples,
          },
          {
            type: "text",
            text: prompt(text, labels),
          },
        ],
      },
    ],
  })

  try {
    let response = parseResponse(msg)

    const result = await createIssueFunc({
      assigneeId: assigneeId,
      title: response.title,
      description: text,
      messageId: messageId,
      peerId: peerId,
      labelIds: response.labelIds,
      currentUserId: currentUserId,
    })

    const encryptedTitle = await encrypt(response.title)

    const externalTaskResult = await db
      .insert(externalTasks)
      .values({
        application: "linear",
        taskId: result?.taskId ?? "",
        status: "todo",
        assignedUserId: BigInt(currentUserId),
        number: result?.identifier ?? "",
        url: result?.link ?? "",
        title: encryptedTitle.encrypted,
        titleIv: encryptedTitle.iv,
        titleTag: encryptedTitle.authTag,
        date: new Date(),
      })
      .returning()

    if (externalTaskResult.length > 0 && externalTaskResult[0]?.id) {
      try {
        const messageExists = await db
          .select({ count: count() })
          .from(messages)
          .where(eq(messages.globalId, BigInt(messageId)))
          .then((result) => result[0]!.count > 0)

        if (messageExists) {
          await db
            .insert(messageAttachments)
            .values({
              messageId: BigInt(messageId),
              externalTaskId: BigInt(externalTaskResult[0].id),
            })
            .returning()
        } else {
          Log.shared.error("Message does not exist, skipping message attachment creation", { messageId })
        }
      } catch (error) {
        Log.shared.error("Failed to create message attachment", { error, messageId })
      }
    }

    if (externalTaskResult.length > 0 && externalTaskResult[0]) {
      try {
        await messageAttachmentUpdate({
          messageId,
          peerId,
          currentUserId,
          externalTask: externalTaskResult[0],
        })
      } catch (error) {
        Log.shared.error("Failed to update message attachment", { error })
      }
    }

    return { link: result?.link }
  } catch (error) {
    Log.shared.error("Failed to create issue", { error })
    return { link: undefined }
  }
}

type CreateIssueProps = {
  assigneeId: string
  title: string
  description: string
  messageId: number
  peerId: TPeerInfo
  labelIds: string[]
  currentUserId: number
}

type CreateIssueResult = {
  link: string
  identifier: string
  taskId: string
}
const createIssueFunc = async (props: CreateIssueProps): Promise<CreateIssueResult | undefined> => {
  try {
    const [teamData, orgData, statusesData] = await Promise.all([
      getLinearTeams({ userId: props.currentUserId }),
      getLinearOrg({ userId: props.currentUserId }),
      getLinearIssueStatuses({ userId: props.currentUserId }),
    ])

    const teamId = teamData?.id ?? ""
    const unstartedStatus = statusesData.workflowStates.find((status: any) => status.type === "unstarted")?.id

    const chatId = "threadId" in props.peerId ? props.peerId.threadId : undefined

    const result = await createIssue({
      userId: props.currentUserId,
      title: props.title,
      description: props.description,
      teamId,
      messageId: props.messageId,
      chatId: chatId ?? 0,
      labelIds: props.labelIds,
      assigneeId: props.assigneeId || undefined,
      statusId: unstartedStatus,
    })

    return result
      ? {
          link: generateIssueLink(result.identifier ?? "", orgData?.urlKey ?? ""),
          identifier: result.identifier ?? "",
          taskId: result.id ?? "",
        }
      : undefined
  } catch (error) {
    Log.shared.error("Failed to create Linear issue", { error })
    return undefined
  }
}

const messageAttachmentUpdate = async ({
  messageId,
  peerId,
  currentUserId,
  externalTask,
}: {
  messageId: number
  peerId: TPeerInfo
  currentUserId: number
  externalTask: DbExternalTask
}): Promise<void> => {
  try {
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

    // Check if the message exists before trying to update it
    const messageExists = await db
      .select({ count: count() })
      .from(messages)
      .where(eq(messages.globalId, BigInt(messageId)))
      .then((result) => result[0]!.count > 0)

    if (!messageExists) {
      Log.shared.error("Message does not exist, skipping message attachment update", { messageId })
      return
    }

    const updateGroup = await getUpdateGroup(peerId, { currentUserId })

    if (updateGroup.type === "users") {
      updateGroup.userIds.forEach((userId: number) => {
        let encodingForPeer: TPeerInfo = userId === currentUserId ? peerId : { userId: currentUserId }
        const update: TUpdateInfo = {
          deleteMessage: {
            messageId,
            peerId: encodingForPeer,
          },
        }

        const updates = [update]

        connectionManager.sendToUser(userId, createMessage({ kind: ServerMessageKind.Message, payload: { updates } }))

        // New updates
        let messageDeletedUpdate: Update = {
          update: {
            oneofKind: "messageAttachment",
            messageAttachment: {
              attachment: {
                messageId: BigInt(messageId),
                attachment: {
                  oneofKind: "externalTask",
                  externalTask: {
                    id: BigInt(externalTask.id),
                    application: "linear",
                    taskId: externalTask.taskId,
                    title: decryptedTitle,
                    status: MessageAttachmentExternalTask_Status.TODO,
                    assignedUserId: BigInt(currentUserId),
                    number: externalTask.number ?? "",
                    url: externalTask.url ?? "",
                    date: BigInt(Date.now().toString()),
                  },
                },
              },
            },
          },
        }
        RealtimeUpdates.pushToUser(userId, [messageDeletedUpdate])
      })
    } else if (updateGroup.type === "space") {
      const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)

      userIds.forEach((userId) => {
        const update: TUpdateInfo = {
          deleteMessage: {
            messageId,
            peerId,
          },
        }

        const updates = [update]

        connectionManager.sendToUser(
          userId,
          createMessage({ kind: ServerMessageKind.Message, payload: { updates: updates } }),
        )

        let messageDeletedUpdate: Update = {
          update: {
            oneofKind: "messageAttachment",
            messageAttachment: {
              attachment: {
                messageId: BigInt(messageId),
                attachment: {
                  oneofKind: "externalTask",
                  externalTask: {
                    id: BigInt(externalTask.id),
                    application: "linear",
                    taskId: externalTask.taskId,
                    title: decryptedTitle,
                    status: MessageAttachmentExternalTask_Status.TODO,
                    assignedUserId: BigInt(currentUserId),
                    number: externalTask.number ?? "",
                    url: externalTask.url ?? "",
                    date: BigInt(Date.now().toString()),
                  },
                },
              },
            },
          },
        }

        RealtimeUpdates.pushToUser(userId, [messageDeletedUpdate])
      })
    }
  } catch (error) {
    Log.shared.error("Failed to update message attachment", { error })
  }
}

function parseResponse(msg: any): any {
  if (!msg.content[0] || msg.content[0].type !== "text") {
    Log.shared.error("Unexpected response format from Anthropic")
    throw new Error("Invalid response format from Anthropic")
  }

  const responseText = (msg.content[0] as { type: "text"; text: string }).text

  let jsonMatch =
    responseText.match(/```json\n([\s\S]*?)\n```/) ||
    responseText.match(/<o>([\s\S]*?)<\/o>/) ||
    responseText.match(/<output>([\s\S]*?)<\/output>/) ||
    responseText.match(/<ideal_output>([\s\S]*?)<\/ideal_output>/) ||
    responseText.match(/```([\s\S]*?)```/) ||
    responseText.match(/\{[\s\S]*"title"[\s\S]*"labelIds"[\s\S]*\}/)

  if (!jsonMatch) {
    Log.shared.error("Failed to extract JSON from Anthropic response", { responseText })
    throw new Error("Invalid response format from Anthropic")
  }

  // If we matched the full JSON object pattern directly
  let jsonString = jsonMatch[1] || jsonMatch[0]

  // Clean up the JSON string
  jsonString = jsonString.trim()

  const jsonResponse = JSON.parse(jsonString)
  return jsonResponse
}
