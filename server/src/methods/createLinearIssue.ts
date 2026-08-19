import { Optional, Type, type Static } from "@sinclair/typebox"
import { eq, and, gte, lte } from "drizzle-orm"
import { chatParticipants, users, messages } from "../db/schema"
import { db } from "../db"
import { z } from "zod/v4"
import {
  createIssue,
  deleteLinearIssue,
  generateIssueLink,
  getLinearIssueLabels,
  getLinearOrg,
  getLinearTeams,
  getLinearUsers,
} from "@in/server/libs/linear"
import { openaiClient } from "../libs/openAI"
import { Log } from "../utils/log"
import { messageAttachments, externalTasks, type DbExternalTask } from "../db/schema/attachments"
import { encrypt } from "../modules/encryption/encryption"
import { TInputPeerInfo, TPeerInfo } from "../api-types"
import { getUpdateGroup } from "../modules/updates"
import { connectionManager } from "../ws/connections"
import { MessageAttachmentExternalTask_Status, type MessageAttachment } from "@inline-chat/protocol/core"
import { zodResponseFormat } from "openai/helpers/zod"
import { RealtimeUpdates } from "../realtime/message"
import { prompt } from "../libs/linear/prompt"
import { Notifications } from "../modules/notifications/notifications"
import { encodeMessageAttachmentUpdate } from "../realtime/encoders/encodeMessageAttachment"
import { ProtocolConvertors } from "@in/server/types/protocolConvertors"
import { resolveProviderActionContext } from "@in/server/modules/integrations/providerActionContext"
import { providerTaskModel, providerTaskReasoningEffort } from "@in/server/modules/integrations/providerTaskModel"
import {
  readStoredTaskMessageText,
  resolveLinearTaskSourceText,
} from "@in/server/libs/linear/taskContext"
import {
  findExistingProviderTask,
  isProviderTaskIdempotencyConflict,
  linearTaskReplayResponse,
  type ProviderTaskIdentity,
} from "@in/server/modules/integrations/providerTaskIdempotency"

const LINEAR_PROVIDER_TIMEOUT_MS = 60_000

type Context = {
  currentUserId: number
  signal?: AbortSignal
}

const providerSignal = (requestSignal: AbortSignal | undefined): AbortSignal =>
  requestSignal === undefined
    ? AbortSignal.timeout(LINEAR_PROVIDER_TIMEOUT_MS)
    : AbortSignal.any([requestSignal, AbortSignal.timeout(LINEAR_PROVIDER_TIMEOUT_MS)])

const throwIfAborted = (signal: AbortSignal): void => {
  if (signal.aborted) throw signal.reason ?? new DOMException("The operation was aborted", "AbortError")
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
  context: Context,
): Promise<Static<typeof Response>> => {
  const { currentUserId } = context
  const signal = providerSignal(context.signal)
  const startTime = Date.now()
  const { messageId, chatId } = input
  throwIfAborted(signal)
  Log.shared.info("Starting Linear issue creation", {
    currentUserId,
    chatId,
    messageId,
    peerType: "userId" in input.peerId ? "dm" : "thread",
    hasExplicitSpaceId: Boolean(input.spaceId),
  })

  let authorized
  try {
    authorized = await resolveProviderActionContext({
      chatId,
      messageId,
      currentUserId,
      claimedSpaceId: input.spaceId,
    })
  } catch (error) {
    if (signal.aborted) throw error
    Log.shared.warn("Linear issue requested without valid chat and space access", {
      chatId,
      messageId,
      currentUserId,
      error,
    })
    return { link: undefined }
  }
  const { message, peerId, spaceId } = authorized
  const taskIdentity: ProviderTaskIdentity = {
    application: "linear",
    assignedUserId: BigInt(currentUserId),
    sourceMessageId: message.globalId,
    connectorSpaceId: spaceId,
  }
  const replay = linearTaskReplayResponse(
    await findExistingProviderTask(taskIdentity),
  )
  if (replay) {
    Log.shared.info("Replayed existing Linear issue creation", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
    })
    return replay
  }
  let createdProviderTaskId: string | null = null
  let providerTaskPersisted = false

  const contextStart = Math.max(1, messageId - 25)
  const contextEnd = messageId + 10

  const loadedContext = await Promise.all([
    getLinearTeams({ spaceId, requireSavedTeam: true, signal }),
    getLinearOrg({ spaceId, signal }),
    getLinearIssueLabels({ spaceId, signal }),
    db.select().from(users).where(eq(users.id, currentUserId)),
    getLinearUsers({ spaceId, signal }),
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
  ]).catch((error) => {
    if (signal.aborted) throw error
    Log.shared.error("Failed to load Linear issue context", { error, chatId, messageId, currentUserId, spaceId })
    return null
  })
  throwIfAborted(signal)
  if (!loadedContext) return { link: undefined }

  const [teamData, orgData, labels, [actorUser], linearUsers, contextMessages, participantRows] = loadedContext
  if (!teamData) {
    Log.shared.warn("No Linear team selected for space; cannot create issue", { spaceId })
    return { link: undefined }
  }
  Log.shared.debug("Fetched Linear issue context", {
    currentUserId,
    chatId,
    messageId,
    spaceId,
    hasMessage: Boolean(message),
    labelCount: labels.labels?.length ?? 0,
    linearUsersCount: linearUsers.users?.length ?? 0,
  })

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
        text: readStoredTaskMessageText(m),
      }))
      .filter((m) => m.text.length > 0)
  })()

  const sourceText = resolveLinearTaskSourceText({
    messageId,
    authorizedMessage: message,
    contextMessages: contextWindow,
  })
  if (!sourceText) {
    Log.shared.warn("Linear issue target message had no readable text", {
      chatId,
      messageId,
      currentUserId,
      spaceId,
    })
    return { link: undefined }
  }

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

  const assigneeByActorEmail = linearUsers.users.find((user) => user.email && user.email === actorUser?.email)?.id

  if (!openaiClient) {
    Log.shared.error("OpenAI client not initialized", { chatId, messageId, currentUserId, spaceId })
    return { link: undefined }
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
  const completion = await openaiClient.chat.completions.parse({
    model: providerTaskModel,
    verbosity: "low",
    reasoning_effort: providerTaskReasoningEffort,
    messages: [
      {
        role: "user",
        content: prompt({
          primaryMessage: {
            author: contextWindow.find((m) => m.messageId === messageId)?.author ?? "Someone",
            text: sourceText,
          },
          surroundingMessages: contextWindow
            .filter((m) => m.messageId !== messageId)
            .map((m) => ({ author: m.author, text: m.text }))
            .slice(-20),
          participants,
          linearWorkspaceUsers: linearUsers.users,
          labels: labels.labels,
        }),
      },
    ],
    response_format: zodResponseFormat(issueSchema, "linearIssue"),
    signal,
  }).catch((error) => {
    if (signal.aborted) throw error
    Log.shared.error("Failed to generate Linear issue data", { error, chatId, messageId, currentUserId, spaceId })
    return null
  })
  if (!completion) return { link: undefined }

  try {
    const response = completion.choices[0]?.message.parsed
    if (!response) {
      throw new Error("Missing parsed OpenAI response")
    }
    Log.shared.debug("OpenAI response parsed for Linear issue", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      issueTitle: response.title,
      labelIdsCount: response.labelIds.length,
    })

    const allowedLabelIds = new Set(labels.labels.map((label) => label.id))
    const filteredLabelIds = response.labelIds
      .filter((id) => allowedLabelIds.has(String(id)))
      .slice(0, 3)
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
        ? linearUsers.users.find((user) => user.id === response.assigneeLinearUserId)?.id
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
      team: teamData,
      organizationUrlKey: orgData?.urlKey ?? "",
      signal,
    })

    if (!result?.taskId) {
      Log.shared.error("Failed to create Linear issue (no result)", { messageId, chatId, currentUserId })
      return { link: undefined }
    }
    createdProviderTaskId = result.taskId
    Log.shared.info("Linear issue created", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      hasTaskId: true,
      hasIdentifier: Boolean(result.identifier),
      hasLink: Boolean(result.link),
    })

    const encryptedTitle = await encrypt(response.title)

    const { externalTask, attachmentRow } = await db.transaction(async (tx) => {
      const [externalTask] = await tx.insert(externalTasks).values({
        application: "linear",
        taskId: result.taskId,
        status: "todo",
        assignedUserId: BigInt(currentUserId),
        connectorSpaceId: spaceId,
        sourceMessageId: message.globalId,
        number: result.identifier ?? "",
        url: result.link ?? "",
        title: encryptedTitle.encrypted,
        titleIv: encryptedTitle.iv,
        titleTag: encryptedTitle.authTag,
        date: new Date(),
      }).returning()
      if (!externalTask?.id) throw new Error("Failed to create Linear external task record")
      const [attachmentRow] = await tx.insert(messageAttachments).values({
        messageId: message.globalId,
        externalTaskId: BigInt(externalTask.id),
      }).returning()
      if (!attachmentRow?.id) throw new Error("Failed to create Linear message attachment")
      return { externalTask, attachmentRow }
    })
    providerTaskPersisted = true
    Log.shared.debug("Created Linear external task record", {
      currentUserId,
      chatId,
      messageId,
      spaceId,
      externalTaskId: externalTask.id,
    })

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
      void sendNotificationToUser({
        userId: messageSenderId,
        actorName: actorUser.firstName ?? "Someone",
        issueTitle: response.title,
        messageText: sourceText,
        currentUserId,
        chatId,
        isThread: peerId && "threadId" in peerId,
      }).then(() => {
        Log.shared.debug("Sent Linear issue push notification to message sender", {
          currentUserId,
          chatId,
          messageId,
          toUserId: messageSenderId,
        })
      }).catch((error) => {
        Log.shared.error("Failed to send Linear task creation notification", {
          error,
          chatId,
          messageId,
          currentUserId,
          toUserId: messageSenderId,
        })
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
    // A provider mutation may have committed even when its response was
    // interrupted. Preserve commit-unknown rather than deleting a task on the
    // basis of the local deadline.
    if (signal.aborted) throw error
    const idempotencyConflict = isProviderTaskIdempotencyConflict(error)
    if (createdProviderTaskId && !providerTaskPersisted) {
      await deleteLinearIssue({ spaceId, issueId: createdProviderTaskId })
        .then((result) => {
          if (!result.success) {
            Log.shared.warn("Failed to compensate untracked Linear issue", {
              spaceId,
              hasIssueId: true,
            })
          }
        })
        .catch((compensationError) => {
          Log.shared.warn("Failed to compensate untracked Linear issue", {
            spaceId,
            hasIssueId: true,
            error: compensationError,
          })
        })
    }
    if (idempotencyConflict) {
      const replay = linearTaskReplayResponse(
        await findExistingProviderTask(taskIdentity),
      )
      if (replay) {
        Log.shared.info("Converged concurrent Linear issue creation", {
          currentUserId,
          chatId,
          messageId,
          spaceId,
        })
        return replay
      }
    }
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
  team: { id: string; key: string }
  organizationUrlKey: string
  signal: AbortSignal
}

type CreateIssueResult = {
  link: string
  identifier: string
  taskId: string
}
const createIssueFunc = async (props: CreateIssueProps): Promise<CreateIssueResult | undefined> => {
  try {
    throwIfAborted(props.signal)
    const chatId = "threadId" in props.peerId ? props.peerId.threadId : undefined
    Log.shared.debug("Creating Linear issue via API", {
      spaceId: props.spaceId,
      teamId: props.team.id,
      teamKey: props.team.key,
      chatId: chatId ?? 0,
      labelIdsCount: props.labelIds.length,
      hasAssignee: Boolean(props.assigneeId),
    })

    // Provider mutation is intentionally single-attempt. Team, labels, and
    // assignee were loaded and allowlisted before this call; retrying an
    // ambiguous network failure could create a duplicate Linear issue.
    const result = await createIssue({
      spaceId: props.spaceId,
      title: props.title,
      description: props.description,
      teamId: props.team.id,
      messageId: props.messageId,
      chatId: chatId ?? 0,
      labelIds: props.labelIds,
      assigneeId: props.assigneeId,
      signal: props.signal,
    })

    return result
      ? {
          link: generateIssueLink(result.identifier ?? "", props.organizationUrlKey),
          identifier: result.identifier ?? "",
          taskId: result.id ?? "",
        }
      : undefined
  } catch (error) {
    if (props.signal.aborted) throw error
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

  await Notifications.sendToUser({
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
