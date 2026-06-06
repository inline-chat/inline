import { db } from "@in/server/db"
import { chats, chatParticipants, userNotDeleted, users, type DbChat, type DbDialog } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  getAnchorMessageForChat,
  getChatById,
  getDialogForUser,
  buildDefaultReplyThreadTitle,
  ensureLinkedSubthreadDialogs,
  isLinkedSubthread,
  persistMessageRepliesUpdate,
  pushMessageRepliesUpdate,
} from "@in/server/modules/subthreads"
import { DIALOG_FOLLOWING, setDialogFollowModeForUsers } from "@in/server/modules/dialogFollow"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import type { Chat, ChatParticipant, Dialog, Message } from "@inline-chat/protocol/core"
import type { Transaction } from "@in/server/db/types"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { allocateSpaceThreadNumber } from "@in/server/modules/threadNumbers"
import { and, eq, inArray } from "drizzle-orm"

type Input = {
  parentChatId: bigint
  parentMessageId?: bigint
  title?: string
  description?: string
  emoji?: string
  participants?: { userId: bigint }[]
}

type Output = {
  chat: Chat
  dialog?: Dialog
  anchorMessage?: Message
}

type InitialParticipant = {
  chatId: number
  userId: number
  date: Date
}

export async function createSubthread(input: Input, context: FunctionContext): Promise<Output> {
  const parentChatId = Number(input.parentChatId)
  if (!Number.isSafeInteger(parentChatId) || parentChatId <= 0) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  const parentMessageId = input.parentMessageId !== undefined ? Number(input.parentMessageId) : undefined
  if (parentMessageId !== undefined && (!Number.isSafeInteger(parentMessageId) || parentMessageId <= 0)) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const parentChat = await getChatById(parentChatId)
  if (!parentChat) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  await AccessGuards.ensureChatAccess(parentChat, context.currentUserId)

  const anchorMessage =
    parentMessageId !== undefined
      ? await getAnchorMessageForChat({ parentChatId, parentMessageId })
      : undefined

  if (parentMessageId !== undefined && !anchorMessage) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const directParticipantUserIds = uniquePositiveUserIds(input.participants ?? [])
  await ensureUsersExist(directParticipantUserIds)

  if (parentMessageId !== undefined) {
    const existingReplyThread = await db.query.chats.findFirst({
      where: {
        parentChatId,
        parentMessageId,
      },
    })

    if (existingReplyThread) {
      await ensureLinkedSubthreadDialogs({
        chat: existingReplyThread,
        userIds: [context.currentUserId],
        chatListHidden: true,
      })
      await autoFollowCreatedReplyThread({
        chat: existingReplyThread,
        currentUserId: context.currentUserId,
        anchorMessage,
      })

      return encodeSubthreadResult({
        chat: existingReplyThread,
        currentUserId: context.currentUserId,
      })
    }
  }

  const explicitTitle = normalizeOptionalString(input.title)
  const title =
    explicitTitle ??
    (parentMessageId !== undefined
      ? buildDefaultReplyThreadTitle(anchorMessage)
      : undefined)
  const description = normalizeOptionalString(input.description)
  const emoji = normalizeOptionalString(input.emoji)

  const chat = await createSubthreadChat({
    parentChat,
    parentMessageId,
    title,
    isUntitled: explicitTitle === undefined,
    description,
    emoji,
    createdBy: context.currentUserId,
    directParticipantUserIds,
  })

  const { dialogs: materializedDialogs } =
    parentMessageId !== undefined
      ? await autoFollowCreatedReplyThread({
          chat,
          currentUserId: context.currentUserId,
          anchorMessage,
        })
      : await ensureLinkedSubthreadDialogs({
          chat,
          userIds: [context.currentUserId],
          chatListHidden: true,
        })

  if (!isLinkedSubthread(chat)) {
    await persistNewChatUpdate(chat.id)
  }

  if (parentMessageId !== undefined) {
    const parentSummaryUpdate = await persistMessageRepliesUpdate({
      parentChatId,
      parentMessageId,
    })

    await pushMessageRepliesUpdate({
      parentChatId,
      parentMessageId,
      currentUserId: context.currentUserId,
      update: parentSummaryUpdate,
    })
  }

  return encodeSubthreadResult({
    chat,
    currentUserId: context.currentUserId,
    dialog: materializedDialogs.find((dialog) => dialog.userId === context.currentUserId),
    anchorMessage,
  })
}

async function autoFollowCreatedReplyThread(input: {
  chat: DbChat
  currentUserId: number
  anchorMessage?: Awaited<ReturnType<typeof getAnchorMessageForChat>>
}): Promise<{ dialogs: DbDialog[] }> {
  const userIds = new Set<number>([input.currentUserId])

  if (input.anchorMessage?.fromId != null) {
    userIds.add(input.anchorMessage.fromId)
  }

  const { dialogs } = await setDialogFollowModeForUsers({
    chat: input.chat,
    userIds: Array.from(userIds),
    followMode: DIALOG_FOLLOWING,
  })

  return { dialogs }
}

async function encodeSubthreadResult(input: {
  chat: DbChat
  currentUserId: number
  dialog?: DbDialog | undefined
  anchorMessage?: Awaited<ReturnType<typeof getAnchorMessageForChat>>
}): Promise<Output> {
  const dialog = input.dialog ?? (await getDialogForUser(input.chat.id, input.currentUserId))

  const anchorMessage = input.anchorMessage ?? (await getAnchorMessageForChat(input.chat))

  return {
    chat: Encoders.chat(input.chat, { encodingForUserId: input.currentUserId }),
    dialog: dialog ? Encoders.dialog(dialog, { unreadCount: 0 }) : undefined,
    anchorMessage: anchorMessage
      ? Encoders.fullMessage({
          message: anchorMessage,
          encodingForUserId: input.currentUserId,
          encodingForPeer: {
            inputPeer: {
              type: {
                oneofKind: "chat",
                chat: { chatId: BigInt(input.chat.parentChatId ?? input.chat.id) },
              },
            },
          },
        })
      : undefined,
  }
}

async function createSubthreadChat(input: {
  parentChat: DbChat
  parentMessageId?: number
  title?: string
  isUntitled: boolean
  description?: string
  emoji?: string
  createdBy: number
  directParticipantUserIds: number[]
}): Promise<DbChat> {
  try {
    const result = await db.transaction(async (tx): Promise<{ chat: DbChat; participants: InitialParticipant[] }> => {
      const spaceId = input.parentChat.spaceId ?? null
      const threadNumber = spaceId !== null ? await allocateSpaceThreadNumber(tx, spaceId) : null

      const [chat] = await tx
        .insert(chats)
        .values({
          type: "thread",
          spaceId,
          title: input.title ?? null,
          isUntitled: input.isUntitled ? true : null,
          description: input.description ?? null,
          emoji: input.emoji ?? null,
          createdBy: input.createdBy,
          publicThread: input.parentChat.publicThread ?? false,
          parentChatId: input.parentChat.id,
          parentMessageId: input.parentMessageId ?? null,
          threadNumber,
        })
        .returning()

      if (!chat) {
        throw RealtimeRpcError.InternalError()
      }

      let participants: InitialParticipant[] = []
      if (input.directParticipantUserIds.length > 0) {
        participants = input.directParticipantUserIds.map((userId) => ({
          chatId: chat.id,
          userId,
          date: new Date(),
        }))

        await tx.insert(chatParticipants).values(participants).onConflictDoNothing()
        await enqueueInitialParticipantAdds(tx, chat.id, participants, input.createdBy)
      }

      return { chat, participants }
    })

    result.participants.forEach((participant) => {
      AccessGuardsCache.setChatParticipant(participant.chatId, participant.userId)
    })

    return result.chat
  } catch (error) {
    if (
      input.parentMessageId !== undefined &&
      error instanceof Error &&
      error.message.includes("reply_thread_parent_unique")
    ) {
      const existingReplyThread = await db.query.chats.findFirst({
        where: {
          parentChatId: input.parentChat.id,
          parentMessageId: input.parentMessageId,
        },
      })

      if (existingReplyThread) {
        return existingReplyThread
      }
    }

    throw error
  }
}

async function ensureUsersExist(userIds: number[]): Promise<void> {
  if (userIds.length === 0) {
    return
  }

  const existingUsers = await db
    .select({ id: users.id })
    .from(users)
    .where(and(inArray(users.id, userIds), userNotDeleted()))

  if (existingUsers.length !== userIds.length) {
    throw RealtimeRpcError.UserIdInvalid()
  }
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : undefined
}

function uniquePositiveUserIds(participants: { userId: bigint }[]): number[] {
  const result = new Set<number>()

  for (const participant of participants) {
    const userId = Number(participant.userId)
    if (!Number.isSafeInteger(userId) || userId <= 0) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    result.add(userId)
  }

  return Array.from(result)
}

async function enqueueInitialParticipantAdds(
  tx: Transaction,
  chatId: number,
  participants: InitialParticipant[],
  currentUserId: number,
): Promise<void> {
  await UserBucketUpdates.enqueueMany(
    participants
      .filter((participant) => participant.userId !== currentUserId)
      .map((participant) => ({
        userId: participant.userId,
        update: {
          oneofKind: "userChatParticipantAdd" as const,
          userChatParticipantAdd: {
            chatId: BigInt(chatId),
            participant: encodeParticipant(participant),
          },
        },
      })),
    { tx },
  )
}

function encodeParticipant(participant: InitialParticipant): ChatParticipant {
  return {
    userId: BigInt(participant.userId),
    date: encodeDateStrict(participant.date),
  }
}

async function persistNewChatUpdate(chatId: number): Promise<UpdateSeqAndDate> {
  const chatUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "newChat",
    newChat: {
      chatId: BigInt(chatId),
    },
  }

  return db.transaction(async (tx): Promise<UpdateSeqAndDate> => {
    const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)

    if (!chat) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: chatUpdatePayload,
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chatId))

    return update
  })
}
