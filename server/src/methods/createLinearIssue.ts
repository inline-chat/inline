import { Optional, Type, type Static } from "@sinclair/typebox"
import { eq, and, gte, lte } from "drizzle-orm"
import { chats, chatParticipants, users, messages } from "../db/schema"
import { db } from "../db"
import { z } from "zod"
import {
  createIssue,
  generateIssueLink,
  getLinearIssueLabels,
  getLinearOrg,
  getLinearTeams,
  getLinearUsers,
} from "@in/server/libs/linear"
import { openaiClient } from "../libs/openAI"
import { Log } from "../utils/log"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import { messageAttachments, externalTasks, type DbExternalTask } from "../db/schema/attachments"
import { encrypt } from "../modules/encryption/encryption"
import { TInputPeerInfo, TPeerInfo } from "../api-types"
import { getUpdateGroup } from "../modules/updates"
import { connectionManager } from "../ws/connections"
import { MessageAttachmentExternalTask_Status, type MessageAttachment } from "@in/protocol/core"
import { RealtimeUpdates } from "../realtime/message"
import { examples, prompt } from "../libs/linear/prompt"
import { Notifications } from "../modules/notifications/notifications"
import { Authorize } from "@in/server/utils/authorize"
import { encodeMessageAttachmentUpdate } from "../realtime/encoders/encodeMessageAttachment"
import { ProtocolConvertors } from "../types/protocolConvertors"
import { decrypt } from "../modules/encryption/encryption"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  text: Type.String(),
  messageId: Type.Number(),
  chatId: Type.Number(),
  peerId: TInputPeerInfo,
  fromId: Type.Number(),
  spaceId: Optional(Type.Number()),
})

export const Response = Type.Object({
  link: Optional(Type.String()),
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const startTime = Date.now()
  let { text, messageId, peerId, chatId } = input
  Log.shared.info("Starting Linear issue creation", {
    currentUserId,
    chatId,
    messageId,
    peerType: "userId" in peerId ? "dm" : "thread",
    hasExplicitSpaceId: Boolean(input.spaceId),
    textLength: text.length,
  })

  // Linear is space-scoped. Prefer the chat's spaceId; for DMs allow an explicit spaceId.
  let spaceId: number | undefined
  try {
    const [chat] = await db.select({ spaceId: chats.spaceId }).from(chats).where(eq(chats.id, chatId))
    spaceId = chat?.spaceId ?? undefined
    if (spaceId) {
      await Authorize.spaceMember(spaceId, currentUserId)
      Log.shared.debug("Resolved Linear space from chat", { chatId, spaceId, currentUserId })
    }
  } catch (error) {
    Log.shared.warn("Linear issue requested without valid space access", { chatId, currentUserId, error })
    return { link: undefined }
  }

  if (!spaceId && input.spaceId) {
    spaceId = input.spaceId
    try {
      await Authorize.spaceMember(spaceId, currentUserId)
      Log.shared.debug("Resolved Linear space from explicit spaceId", { chatId, spaceId, currentUserId })
    } catch (error) {
      Log.shared.warn("Linear issue requested without valid space access", {
        chatId,
        currentUserId,
        spaceId,
        error,
      })
      return { link: undefined }
    }
  }

  if (!spaceId) {
    Log.shared.warn("Linear issue requested outside a space", { peerId, chatId, currentUserId })
    return { link: undefined }
  }

  const contextStart = Math.max(1, messageId - 25)
  const contextEnd = messageId + 10

  const [[message], labels, [actorUser], linearUsers, contextMessages, participantRows] = await Promise.all([
    db
      .select()
      .from(messages)
      .where(and(eq(messages.messageId, messageId), eq(messages.chatId, chatId))),
    getLinearIssueLabels({ spaceId }),
    db.select().from(users).where(eq(users.id, currentUserId)),
    getLinearUsers({ spaceId }),
    db
      .select({
        messageId: messages.messageId,
        fromId: messages.fromId,
        text: messages.text,
        textEncrypted: messages.textEncrypted,
        textIv: messages.textIv,
        textTag: messages.textTag,
        date: messages.date,
        firstName: users.firstName,
        lastName: users.lastName,
        username: users.username,
        email: users.email,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(and(eq(messages.chatId, chatId), gte(messages.messageId, contextStart), lte(messages.messageId, contextEnd)))
      .orderBy(messages.messageId)
      .limit(40),
    db
      .select({
        userId: users.id,
        firstName: users.firstName,
        lastName: users.lastName,
        username: users.username,
        email: users.email,
      })
      .from(chatParticipants)
      .innerJoin(users, eq(chatParticipants.userId, users.id))
      .where(eq(chatParticipants.chatId, chatId))
      .limit(50),
  ])
  Log.shared.debug("Fetched Linear issue context", {
    currentUserId,
    chatId,
    messageId,
    spaceId,
    hasMessage: Boolean(message),
    labelCount: labels.labels?.length ?? 0,
    linearUsersCount: linearUsers.users?.length ?? 0,
  })

  if (!message) {
    Log.shared.error("Message does not exist, cannot create Linear issue attachment", { messageId, chatId })
    return { link: undefined }
  }

  const safeMessageText = (row: {
    text: string | null
    textEncrypted: Buffer | null
    textIv: Buffer | null
    textTag: Buffer | null
  }): string => {
    if (row.text && row.text.trim().length > 0) return row.text
    if (row.textEncrypted && row.textIv && row.textTag) {
      try {
        return decrypt({ encrypted: row.textEncrypted, iv: row.textIv, authTag: row.textTag })
      } catch {
        return ""
      }
    }
    return ""
  }

  const displayNameFor = (row: { firstName: string | null; lastName: string | null; username: string | null }) => {
    const first = row.firstName?.trim()
    const last = row.lastName?.trim()
    if (first && last) return `${first} ${last}`
    if (first) return first
    if (row.username) return row.username
    return "Someone"
  }

  const contextWindow = (() => {
    return contextMessages
      .map((m) => ({
        messageId: m.messageId,
        fromId: m.fromId,
        author: displayNameFor(m),
        email: m.email,
        text: safeMessageText(m).trim(),
      }))
      .filter((m) => m.text.length > 0)
  })()

  const participants = (() => {
    const merged = [
      ...participantRows.map((p) => ({
        displayName: displayNameFor(p),
        email: p.email,
      })),
      ...contextWindow.map((m) => ({
        displayName: m.author,
        email: m.email,
      })),
    ]

    const seen = new Set<string>()
    return merged.filter((p) => {
      const key = `${(p.email ?? "").toLowerCase()}|${p.displayName.toLowerCase()}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
  })()

  const assigneeByActorEmail = linearUsers.users.find((u: any) => u.email && u.email === actorUser?.email)?.id

  if (!openaiClient) {
    throw new Error("OpenAI client not initialized")
  }

  const issueSchema = z.object({
    title: z.string(),
    description: z.string(),
    labelIds: z.array(z.string()).default([]),
    assigneeLinearUserId: z.string().nullable().optional(),
  })

  Log.shared.info("Generating Linear issue title via OpenAI", {
    currentUserId,
    chatId,
    messageId,
    spaceId,
    labelCount: labels.labels?.length ?? 0,
  })
  const completion = await openaiClient.chat.completions.create({
    model: "gpt-5.2",
    verbosity: "low",
    reasoning_effort: "low",
    messages: [
      {
        role: "user",
        content: `${prompt({
          primaryMessage: {
            author: contextWindow.find((m) => m.messageId === messageId)?.author ?? "Someone",
            text,
          },
          surroundingMessages: contextWindow
            .filter((m) => m.messageId !== messageId)
            .map((m) => ({ author: m.author, text: m.text }))
            .slice(-20),
          participants,
          linearWorkspaceUsers: (linearUsers.users ?? []).map((u: any) => ({
            id: u.id,
            name: u.name,
            email: u.email,
          })),
          labels: (labels.labels ?? []).map((l: any) => ({ id: l.id, name: l.name })),
        })}`,
      },
    ],
    response_format: zodResponseFormat(issueSchema, "linearIssue"),
  })

  try {
    const parsedResponse = completion.choices[0]?.message?.content
    if (!parsedResponse) {
      throw new Error("Missing OpenAI response")
    }

    const response = issueSchema.parse(JSON.parse(parsedResponse))
    Log.shared.debug("OpenAI response parsed for Linear issue", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      issueTitle: response.title,
      labelIdsCount: response.labelIds.length,
    })

    const allowedLabelIds = new Set<string>((labels.labels ?? []).map((l: any) => String(l.id)))
    const filteredLabelIds = response.labelIds.filter((id) => allowedLabelIds.has(String(id)))
    const droppedLabelIdsCount = response.labelIds.length - filteredLabelIds.length
    if (droppedLabelIdsCount > 0) {
      Log.shared.warn("Dropping invalid labelIds from OpenAI response", {
        currentUserId,
        chatId,
        messageId,
        spaceId,
        droppedLabelIdsCount,
        originalCount: response.labelIds.length,
        filteredCount: filteredLabelIds.length,
      })
    }

    const assigneeId =
      (response.assigneeLinearUserId
        ? linearUsers.users.find((u: any) => u.id === response.assigneeLinearUserId)?.id
        : undefined) ?? assigneeByActorEmail

    const result = await createIssueFunc({
      assigneeId,
      title: response.title,
      description: response.description,
      messageId: messageId,
      peerId: peerId,
      labelIds: filteredLabelIds,
      currentUserId: currentUserId,
      spaceId,
    })

    if (!result?.taskId) {
      Log.shared.error("Failed to create Linear issue (no result)", { messageId, chatId, currentUserId })
      return { link: undefined }
    }
    Log.shared.info("Linear issue created", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      linearTaskId: result.taskId,
      identifier: result.identifier,
      link: result.link,
    })

    const encryptedTitle = await encrypt(response.title)

    const [externalTask] = await db
      .insert(externalTasks)
      .values({
        application: "linear",
        taskId: result.taskId,
        status: "todo",
        assignedUserId: BigInt(currentUserId),
        number: result.identifier ?? "",
        url: result.link ?? "",
        title: encryptedTitle.encrypted,
        titleIv: encryptedTitle.iv,
        titleTag: encryptedTitle.authTag,
        date: new Date(),
      })
      .returning()

    if (!externalTask?.id) {
      Log.shared.error("Failed to create Linear external task record", { messageId, chatId, currentUserId })
      return { link: undefined }
    }
    Log.shared.debug("Created Linear external task record", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      externalTaskId: externalTask.id,
    })

    const [attachmentRow] = await db
      .insert(messageAttachments)
      .values({
        // FK references messages.globalId (not messages.messageId)
        messageId: message.globalId,
        externalTaskId: BigInt(externalTask.id),
      })
      .returning()

    if (!attachmentRow?.id) {
      Log.shared.error("Failed to create message attachment", { messageId, chatId, currentUserId })
      return { link: result.link }
    }
    Log.shared.debug("Created message attachment row for Linear external task", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      messageGlobalId: message.globalId?.toString(),
      messageAttachmentId: attachmentRow.id,
      externalTaskId: externalTask.id,
    })

    await pushMessageAttachmentUpdate({
      messageId,
      chatId,
      peerId,
      currentUserId,
      messageAttachmentId: BigInt(attachmentRow.id),
      externalTask,
      taskTitle: response.title,
    })

    const messageSenderId = message.fromId
    if (actorUser && messageSenderId && messageSenderId !== currentUserId) {
      sendNotificationToUser({
        userId: messageSenderId,
        actorName: actorUser.firstName ?? "Someone",
        issueTitle: response.title,
        messageText: text,
        currentUserId,
        chatId,
        isThread: peerId && "threadId" in peerId,
      })
      Log.shared.debug("Sent Linear issue push notification to message sender", {
        currentUserId,
        chatId,
        messageId,
        toUserId: messageSenderId,
      })
    }

    Log.shared.info("Completed Linear issue creation", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      durationMs: Date.now() - startTime,
    })
    return { link: result.link }
  } catch (error) {
    Log.shared.error("Failed to create Linear issue", { error, chatId, messageId, currentUserId })
    return { link: undefined }
  }
}

type CreateIssueProps = {
  spaceId: number
  assigneeId?: string
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
    const [teamData, orgData] = await Promise.all([
      getLinearTeams({ spaceId: props.spaceId, requireSavedTeam: true }),
      getLinearOrg({ spaceId: props.spaceId }),
    ])

    const teamId = teamData?.id
    if (!teamId) {
      Log.shared.warn("No Linear team selected for space; cannot create issue", { spaceId: props.spaceId })
      return undefined
    }

    const chatId = "threadId" in props.peerId ? props.peerId.threadId : undefined
    Log.shared.debug("Creating Linear issue via API", {
      spaceId: props.spaceId,
      teamId,
      teamKey: teamData?.key,
      chatId: chatId ?? 0,
      labelIdsCount: props.labelIds.length,
      hasAssignee: Boolean(props.assigneeId),
    })

    type LinearIssue = Awaited<ReturnType<typeof createIssue>>

    const createIssueAttempt = async ({
      assigneeId,
      labelIds,
    }: {
      assigneeId: string | undefined
      labelIds: string[]
    }): Promise<LinearIssue> => {
      return await createIssue({
        spaceId: props.spaceId,
        title: props.title,
        description: props.description,
        teamId,
        messageId: props.messageId,
        chatId: chatId ?? 0,
        labelIds,
        assigneeId,
      })
    }

    let assigneeIdToUse = props.assigneeId || undefined
    let labelIdsToUse = props.labelIds

    let result: LinearIssue
    try {
      result = await createIssueAttempt({ assigneeId: assigneeIdToUse, labelIds: labelIdsToUse })
    } catch (error) {
      if (assigneeIdToUse) {
        Log.shared.warn("Linear issue create failed; retrying without assignee", {
          spaceId: props.spaceId,
          teamId,
          chatId: chatId ?? 0,
          error,
        })
        assigneeIdToUse = undefined
        try {
          result = await createIssueAttempt({ assigneeId: assigneeIdToUse, labelIds: labelIdsToUse })
        } catch (retryError) {
          error = retryError
        }
      }

      if (!result && labelIdsToUse.length > 0) {
        Log.shared.warn("Linear issue create failed; retrying without labels", {
          spaceId: props.spaceId,
          teamId,
          chatId: chatId ?? 0,
          error,
        })
        labelIdsToUse = []
        result = await createIssueAttempt({ assigneeId: assigneeIdToUse, labelIds: labelIdsToUse })
      }
    }

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

/** Send push notifications for this message */
async function sendNotificationToUser({
  userId,
  actorName,
  issueTitle,
  messageText,
  currentUserId,
  chatId,
  isThread,
}: {
  userId: number
  actorName: string
  issueTitle: string
  messageText: string
  currentUserId: number
  chatId: number
  isThread: boolean
}) {
  const title = `${actorName} created a Linear issue`
  const body = messageText || `"${issueTitle}"`

  Notifications.sendToUser({
    userId,
    payload: {
      kind: "alert",
      senderUserId: currentUserId,
      threadId: `chat_${chatId}`,
      title,
      body,
      subtitle: issueTitle,
      isThread,
    },
  })
}

const pushMessageAttachmentUpdate = async ({
  messageId,
  chatId,
  peerId,
  currentUserId,
  messageAttachmentId,
  externalTask,
  taskTitle,
}: {
  messageId: number
  chatId: number
  peerId: TPeerInfo
  currentUserId: number
  messageAttachmentId: bigint
  externalTask: DbExternalTask
  taskTitle: string
}): Promise<void> => {
  try {
    const updateGroup = await getUpdateGroup(peerId, { currentUserId })
    Log.shared.info("Pushing messageAttachment update for Linear external task", {
      currentUserId,
      chatId,
      messageId,
      updateGroupType: updateGroup.type,
      messageAttachmentId: messageAttachmentId.toString(),
      externalTaskId: externalTask.id,
    })

    const attachment: MessageAttachment = {
      id: messageAttachmentId,
      attachment: {
        oneofKind: "externalTask",
        externalTask: {
          id: BigInt(externalTask.id),
          application: "linear",
          taskId: externalTask.taskId,
          title: taskTitle,
          status: MessageAttachmentExternalTask_Status.TODO,
          assignedUserId: BigInt(currentUserId),
          number: externalTask.number ?? "",
          url: externalTask.url ?? "",
          date: BigInt(Math.round(Date.now() / 1000)),
        },
      },
    }

    const inputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer(peerId)

    if (updateGroup.type === "dmUsers") {
      const currentUserInputPeer = ProtocolConvertors.zodPeerToProtocolInputPeer({ userId: currentUserId })
      Log.shared.debug("Sending Linear attachment update to dmUsers", {
        currentUserId,
        chatId,
        messageId,
        recipientCount: updateGroup.userIds.length,
        userIds: updateGroup.userIds,
      })
      updateGroup.userIds.forEach((userId: number) => {
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
      return
    }

    if (updateGroup.type === "threadUsers") {
      Log.shared.debug("Sending Linear attachment update to threadUsers", {
        currentUserId,
        chatId,
        messageId,
        recipientCount: updateGroup.userIds.length,
      })
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
      return
    }

    if (updateGroup.type === "spaceUsers") {
      const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
      Log.shared.debug("Sending Linear attachment update to spaceUsers", {
        currentUserId,
        chatId,
        messageId,
        spaceId: updateGroup.spaceId,
        recipientCount: userIds.length,
      })
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
    Log.shared.error("Failed to push message attachment update", { error })
  }
}
