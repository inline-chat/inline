import { db } from "@in/server/db"
import { chats, chatParticipants, dialogs, members, type DbChat } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { and, eq, inArray, isNull, notInArray, or } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { Update } from "@inline-chat/protocol/core"
import { getUpdateGroup, type UpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

const log = new Log("functions.updateChatVisibility")

type UpdateChatVisibilityInput = {
  chatId: number
  isPublic: boolean
  participants?: number[]
}

type UpdateChatVisibilityOutput = {
  chat: DbChat
  removedUserIds: number[]
  update: { seq: number; date: Date }
}

export async function updateChatVisibility(
  input: UpdateChatVisibilityInput,
  context: FunctionContext,
): Promise<{ chat: DbChat }> {
  const chatId = Number(input.chatId)
  if (!Number.isSafeInteger(chatId) || chatId <= 0) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  const isPublic = Boolean(input.isPublic)

  let removedUserIds: number[] = []
  let updatedChat: DbChat | undefined
  let persistedUpdate: { seq: number; date: Date } | undefined

  try {
    const result = await db.transaction(async (tx): Promise<UpdateChatVisibilityOutput> => {
      const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)

      if (!chat) {
        throw RealtimeRpcError.ChatIdInvalid()
      }

      if (!chat.spaceId || chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a space thread", 400)
      }

      const [member] = await tx
        .select()
        .from(members)
        .where(and(eq(members.spaceId, chat.spaceId), eq(members.userId, context.currentUserId)))
        .limit(1)

      const isCreator = chat.createdBy === context.currentUserId
      if (!member || (!isCreator && member.role !== "admin" && member.role !== "owner")) {
        throw RealtimeRpcError.SpaceAdminRequired()
      }

      if (isPublic) {
        if (input.participants && input.participants.length > 0) {
          throw new RealtimeRpcError(
            RealtimeRpcError.Code.BAD_REQUEST,
            "Participants should be empty for public threads",
            400,
          )
        }

        const removedRows = await tx
          .select({ userId: chatParticipants.userId })
          .from(chatParticipants)
          .leftJoin(
            members,
            and(eq(members.spaceId, chat.spaceId), eq(members.userId, chatParticipants.userId)),
          )
          .where(
            and(
              eq(chatParticipants.chatId, chatId),
              or(isNull(members.userId), eq(members.canAccessPublicChats, false)),
            ),
          )

        removedUserIds = removedRows.map((row) => row.userId)

        if (removedUserIds.length > 0) {
          await tx
            .delete(dialogs)
            .where(and(eq(dialogs.chatId, chatId), inArray(dialogs.userId, removedUserIds)))
        }

        await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chatId))
      } else {
        const inputParticipantIds = input.participants ?? []
        if (inputParticipantIds.length === 0) {
          throw new RealtimeRpcError(
            RealtimeRpcError.Code.BAD_REQUEST,
            "Participants are required for private threads",
            400,
          )
        }

        const uniqueParticipantIds = Array.from(new Set(inputParticipantIds.map((id) => Number(id)))).filter(
          (id) => Number.isSafeInteger(id) && id > 0,
        )

        if (!uniqueParticipantIds.includes(context.currentUserId)) {
          uniqueParticipantIds.push(context.currentUserId)
        }

        const validMembers = await tx
          .select({ userId: members.userId })
          .from(members)
          .where(and(eq(members.spaceId, chat.spaceId), inArray(members.userId, uniqueParticipantIds)))

        if (validMembers.length !== uniqueParticipantIds.length) {
          throw new RealtimeRpcError(
            RealtimeRpcError.Code.BAD_REQUEST,
            "All participants must be space members",
            400,
          )
        }

        const removedRows = await tx
          .select({ userId: dialogs.userId })
          .from(dialogs)
          .where(and(eq(dialogs.chatId, chatId), notInArray(dialogs.userId, uniqueParticipantIds)))

        removedUserIds = removedRows.map((row) => row.userId)

        if (removedUserIds.length > 0) {
          await tx
            .delete(dialogs)
            .where(and(eq(dialogs.chatId, chatId), inArray(dialogs.userId, removedUserIds)))
        }

        await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chatId))

        await tx.insert(chatParticipants).values(
          uniqueParticipantIds.map((userId) => ({
            chatId,
            userId,
            date: new Date(),
          })),
        )
      }

      const chatUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "chatVisibility",
        chatVisibility: {
          chatId: BigInt(chat.id),
          isPublic: isPublic,
        },
      }

      const update = await UpdatesModel.insertUpdate(tx, {
        update: chatUpdatePayload,
        bucket: UpdateBucket.Chat,
        entity: chat,
      })

      const [chatRecord] = await tx
        .update(chats)
        .set({
          publicThread: isPublic,
          updateSeq: update.seq,
          lastUpdateDate: update.date,
        })
        .where(eq(chats.id, chat.id))
        .returning()

      if (!chatRecord) {
        throw RealtimeRpcError.InternalError()
      }

      // NOTE: We only enqueue user-bucket updates for removals. Newly added participants
      // (or newly eligible public members) discover chats via getChats.
      await UserBucketUpdates.enqueueMany(
        removedUserIds.map((userId) => ({
          userId,
          update: {
            oneofKind: "userChatParticipantDelete",
            userChatParticipantDelete: {
              chatId: BigInt(chat.id),
            },
          },
        })),
        { tx },
      )

      return { chat: chatRecord, removedUserIds, update }
    })

    updatedChat = result.chat
    removedUserIds = result.removedUserIds
    persistedUpdate = result.update
  } catch (error) {
    log.error("Failed to update chat visibility", { chatId, error })
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to update chat visibility", 500)
  }

  if (!updatedChat || !persistedUpdate) {
    throw RealtimeRpcError.InternalError()
  }

  AccessGuardsCache.resetChatParticipant(updatedChat.id)
  removedUserIds.forEach((userId) => AccessGuardsCache.resetChatParticipant(updatedChat!.id, userId))

  await pushUpdates({
    chat: updatedChat,
    isPublic,
    removedUserIds,
    currentUserId: context.currentUserId,
    update: persistedUpdate,
  })

  return { chat: updatedChat }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

const pushUpdates = async ({
  chat,
  isPublic,
  removedUserIds,
  currentUserId,
  update,
}: {
  chat: DbChat
  isPublic: boolean
  removedUserIds: number[]
  currentUserId: number
  update: { seq: number; date: Date }
}): Promise<{ updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chat.id }, { currentUserId })

  updateGroup.userIds.forEach((userId) => {
    const updates: Update[] = [
      {
        update: {
          oneofKind: "newChat",
          newChat: {
            chat: Encoders.chat(chat, { encodingForUserId: userId }),
          },
        },
      },
      {
        seq: update.seq,
        date: encodeDateStrict(update.date),
        update: {
          oneofKind: "chatVisibility",
          chatVisibility: {
            chatId: BigInt(chat.id),
            isPublic: isPublic,
          },
        },
      },
    ]

    RealtimeUpdates.pushToUser(userId, updates)
  })

  removedUserIds.forEach((userId) => {
    const participantDelete: Update = {
      update: {
        oneofKind: "participantDelete",
        participantDelete: {
          chatId: BigInt(chat.id),
          userId: BigInt(userId),
        },
      },
    }

    if (!isPublic) {
      updateGroup.userIds.forEach((updateUserId) => {
        RealtimeUpdates.pushToUser(updateUserId, [participantDelete])
      })
    }

    RealtimeUpdates.pushToUser(userId, [participantDelete])
  })

  return { updateGroup }
}
