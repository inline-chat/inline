import { db } from "@in/server/db"
import { chats, chatParticipants, users, type DbChat, type DbDialog } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  buildDefaultReplyThreadTitle,
  getAnchorMessageForChat,
  getChatById,
  getDialogForUser,
  ensureLinkedSubthreadDialogs,
  isLinkedSubthread,
  persistMessageRepliesUpdate,
  pushMessageRepliesUpdate,
} from "@in/server/modules/subthreads"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import type { Chat, Dialog, Message } from "@inline-chat/protocol/core"
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
      const { dialogs } = await ensureLinkedSubthreadDialogs({
        chat: existingReplyThread,
        userIds: [context.currentUserId],
        sidebarVisible: false,
      })

      return encodeSubthreadResult({
        chat: existingReplyThread,
        currentUserId: context.currentUserId,
        dialog: dialogs.find((dialog) => dialog.userId === context.currentUserId),
      })
    }
  }

  const title = normalizeOptionalString(input.title) ?? buildDefaultReplyThreadTitle(anchorMessage)
  const description = normalizeOptionalString(input.description)
  const emoji = normalizeOptionalString(input.emoji)

  const chat = await createSubthreadChat({
    parentChat,
    parentMessageId,
    title,
    description,
    emoji,
    createdBy: context.currentUserId,
    directParticipantUserIds,
  })

  const { dialogs: materializedDialogs } = await ensureLinkedSubthreadDialogs({
    chat,
    userIds: [context.currentUserId],
    sidebarVisible: false,
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
  title: string
  description?: string
  emoji?: string
  createdBy: number
  directParticipantUserIds: number[]
}): Promise<DbChat> {
  try {
    return await db.transaction(async (tx) => {
      const [chat] = await tx
        .insert(chats)
        .values({
          type: "thread",
          spaceId: input.parentChat.spaceId ?? null,
          title: input.title,
          description: input.description ?? null,
          emoji: input.emoji ?? null,
          createdBy: input.createdBy,
          publicThread: input.parentChat.publicThread ?? false,
          parentChatId: input.parentChat.id,
          parentMessageId: input.parentMessageId ?? null,
          threadNumber: null,
        })
        .returning()

      if (!chat) {
        throw RealtimeRpcError.InternalError()
      }

      if (input.directParticipantUserIds.length > 0) {
        const participants = input.directParticipantUserIds.map((userId) => ({
          chatId: chat.id,
          userId,
          date: new Date(),
        }))

        await tx.insert(chatParticipants).values(participants).onConflictDoNothing()
        participants.forEach((participant) => {
          AccessGuardsCache.setChatParticipant(participant.chatId, participant.userId)
        })
      }

      return chat
    })
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
    .where(inArray(users.id, userIds))

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
