import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { chatParticipantGroups } from "@in/server/db/schema/userGroups"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { users } from "@in/server/db/schema/users"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroup } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import type { Update } from "@inline-chat/protocol/core"
import { UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { ensureCanManageChatParticipants } from "@in/server/modules/authorization/spaceThreadGuards"
import { ensureGroupCanParticipateInChat, loadActiveGroupMemberIds } from "@in/server/modules/userGroups"

export async function removeChatParticipant(
  input: {
    chatId: number
    userId?: number
    groupId?: number
  },
  context: FunctionContext,
): Promise<void> {
  try {
    const userId = input.userId
    const groupId = input.groupId
    if ((userId == null && groupId == null) || (userId != null && groupId != null)) {
      throw RealtimeRpcError.BadRequest()
    }

    if (groupId != null) {
      await removeChatParticipantGroup({ chatId: input.chatId, groupId }, context)
      return
    }
    if (userId == null) {
      throw RealtimeRpcError.BadRequest()
    }

    const { update } = await db.transaction(async (tx): Promise<{ update: UpdateSeqAndDate }> => {
      const [chat] = await tx.select().from(chats).where(eq(chats.id, input.chatId)).for("update").limit(1)

      if (!chat) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
      }

      if (chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
      }

      await ensureCanManageChatParticipants(chat, context.currentUserId)

      const user = await tx.select().from(users).where(eq(users.id, userId)).limit(1)
      if (!user || user.length === 0) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `User with ID ${userId} not found`, 404)
      }

      const [participant] = await tx
        .select()
        .from(chatParticipants)
        .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, userId)))

      if (!participant) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "User is not a participant of this chat", 404)
      }

      await tx
        .delete(chatParticipants)
        .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, userId)))

      AccessGuardsCache.resetChatParticipant(input.chatId, userId)

      const chatServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "participantDelete",
        participantDelete: {
          chatId: BigInt(input.chatId),
          userId: BigInt(userId),
        },
      }

      const userServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: BigInt(input.chatId),
        },
      }

      const update = await UpdatesModel.insertUpdate(tx, {
        update: chatServerUpdatePayload,
        bucket: UpdateBucket.Chat,
        entity: chat,
      })

      await tx
        .update(chats)
        .set({
          updateSeq: update.seq,
          lastUpdateDate: update.date,
        })
        .where(eq(chats.id, chat.id))

      await UserBucketUpdates.enqueue(
        {
          userId,
          update: userServerUpdatePayload,
        },
        { tx },
      )

      return { update }
    })

    await pushUpdates({
      chatId: input.chatId,
      userId,
      currentUserId: context.currentUserId,
      update,
    })
  } catch (error) {
    Log.shared.error(`Failed to remove participant from chat ${input.chatId}: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to remove chat participant", 500)
  }
}

async function removeChatParticipantGroup(
  input: { chatId: number; groupId: number },
  context: FunctionContext,
): Promise<void> {
  const { update, affectedUserIds } = await db.transaction(
    async (tx): Promise<{ update: UpdateSeqAndDate; affectedUserIds: number[] }> => {
      const [chat] = await tx.select().from(chats).where(eq(chats.id, input.chatId)).for("update").limit(1)

      if (!chat) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
      }

      if (chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
      }

      await ensureCanManageChatParticipants(chat, context.currentUserId)
      await ensureGroupCanParticipateInChat(chat, input.groupId)

      const [participant] = await tx
        .select()
        .from(chatParticipantGroups)
        .where(and(eq(chatParticipantGroups.chatId, input.chatId), eq(chatParticipantGroups.groupId, input.groupId)))

      if (!participant) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Group is not a participant of this chat", 404)
      }

      const affectedUserIds = await loadActiveGroupMemberIds(input.groupId)

      await tx
        .delete(chatParticipantGroups)
        .where(and(eq(chatParticipantGroups.chatId, input.chatId), eq(chatParticipantGroups.groupId, input.groupId)))

      const chatServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "participantGroupDelete",
        participantGroupDelete: {
          chatId: BigInt(input.chatId),
          groupId: BigInt(input.groupId),
        },
      }

      const update = await UpdatesModel.insertUpdate(tx, {
        update: chatServerUpdatePayload,
        bucket: UpdateBucket.Chat,
        entity: chat,
      })

      await tx
        .update(chats)
        .set({
          updateSeq: update.seq,
          lastUpdateDate: update.date,
        })
        .where(eq(chats.id, chat.id))

      await Promise.all(
        affectedUserIds.map((memberId) =>
          UserBucketUpdates.enqueue(
            {
              userId: memberId,
              update: {
                oneofKind: "userChatParticipantGroupDelete",
                userChatParticipantGroupDelete: {
                  chatId: BigInt(input.chatId),
                  groupId: BigInt(input.groupId),
                },
              },
            },
            { tx },
          ),
        ),
      )

      return { update, affectedUserIds }
    },
  )

  await pushGroupDeleteUpdates({
    chatId: input.chatId,
    groupId: input.groupId,
    currentUserId: context.currentUserId,
    affectedUserIds,
    update,
  })
}

/** Push updates for new chat creation */
const pushUpdates = async ({
  chatId,
  userId,
  currentUserId,
  update,
}: {
  chatId: number
  userId: number
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chatId }, { currentUserId })

  let selfUpdates: Update[] = []

  const chatParticipantDelete: Update = {
    seq: update.seq,
    date: encodeDateStrict(update.date),
    update: {
      oneofKind: "participantDelete",
      participantDelete: {
        chatId: BigInt(chatId),
        userId: BigInt(userId),
      },
    },
  }
  updateGroup.userIds.forEach((updateUserId) => {
    RealtimeUpdates.pushToUser(updateUserId, [chatParticipantDelete])

    if (updateUserId === currentUserId) {
      selfUpdates = [chatParticipantDelete]
    }
  })

  // Send to deleted user.
  // Because they're no longer in the chat topic we still need to deliver the realtime
  // event directly (the user-bucket update handles offline sync).
  RealtimeUpdates.pushToUser(userId, [chatParticipantDelete])

  return { selfUpdates, updateGroup }
}

const pushGroupDeleteUpdates = async ({
  chatId,
  groupId,
  currentUserId,
  affectedUserIds,
  update,
}: {
  chatId: number
  groupId: number
  currentUserId: number
  affectedUserIds: number[]
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chatId }, { currentUserId })
  const targetUserIds = new Set([...updateGroup.userIds, ...affectedUserIds])

  let selfUpdates: Update[] = []

  const chatParticipantGroupDelete: Update = {
    seq: update.seq,
    date: encodeDateStrict(update.date),
    update: {
      oneofKind: "participantGroupDelete",
      participantGroupDelete: {
        chatId: BigInt(chatId),
        groupId: BigInt(groupId),
      },
    },
  }

  targetUserIds.forEach((updateUserId) => {
    RealtimeUpdates.pushToUser(updateUserId, [chatParticipantGroupDelete])

    if (updateUserId === currentUserId) {
      selfUpdates = [chatParticipantGroupDelete]
    }
  })

  return { selfUpdates, updateGroup }
}
