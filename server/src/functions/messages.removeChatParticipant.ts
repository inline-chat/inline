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
import { retryParticipantMutation } from "@in/server/modules/updates/participantMutationRetry"
import { pushChatCatchupHintsBestEffort, pushParticipantUserUpdateBestEffort } from "@in/server/modules/updates/participantLiveUpdates"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import {
  prepareChatPermissionUpdates,
  pushChatPermissionUpdates,
  type PreparedChatPermissionUpdate,
} from "@in/server/modules/authorization/chatPermissionUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { ensureCanManageChatParticipants } from "@in/server/modules/authorization/spaceThreadGuards"
import { ensureGroupCanParticipateInChat, loadActiveGroupMemberIds } from "@in/server/modules/userGroups"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"
import {
  getRootChatIdsForAccessEvents,
  getEffectiveChatAccessUserIds,
  removedAccessUserIds,
} from "@in/server/modules/authorization/chatAccessProjection"

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

    const { update, accessUpdates, permissionUpdates } = await retryParticipantMutation(() => db.transaction(async (tx): Promise<{
      update: UpdateSeqAndDate
      accessUpdates: { chatId: number; update: UpdateSeqAndDate }[]
      permissionUpdates: PreparedChatPermissionUpdate[]
    }> => {
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

      const accessEventChatIds = await getRootChatIdsForAccessEvents(tx, [input.chatId])
      const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)

      await tx
        .delete(chatParticipants)
        .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, userId)))

      const chatServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "participantDelete",
        participantDelete: {
          chatId: BigInt(input.chatId),
          userId: BigInt(userId),
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

      const accessAfter = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)
      const lostChatIds = accessEventChatIds.filter((affectedChatId) =>
        removedAccessUserIds(affectedChatId, accessBefore, accessAfter).includes(userId),
      )
      const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
        lostChatIds.map((affectedChatId) => ({
          userId,
          update: {
            oneofKind: "userRemovedFromChat" as const,
            userRemovedFromChat: { chatId: BigInt(affectedChatId) },
          },
        })),
        { tx },
      )
      const accessUpdates = lostChatIds.map((chatId, index) => ({
        chatId,
        update: persistedAccessUpdates[index]!,
      }))
      const permissionUpdates = await prepareChatPermissionUpdates(
        { userIds: [userId], chatIds: [input.chatId] },
        { tx },
      )

      return { update, accessUpdates, permissionUpdates }
    }))

    try {
      // Cache effects belong after the successfully committed attempt.
      AccessGuardsCache.resetChatParticipant(input.chatId, userId)
      for (const accessUpdate of accessUpdates) {
        await pushUserRemovedFromChat(userId, accessUpdate.chatId, undefined, accessUpdate.update)
      }
      await pushChatPermissionUpdates(permissionUpdates)
      await pushUpdates({ chatId: input.chatId, userId, currentUserId: context.currentUserId, update })
      const [chat] = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)
      if (chat) BotUpdateProjector.participationChanged({ botUserId: userId, chat, actorUserId: context.currentUserId, added: false })
    } catch (error) {
      Log.shared.warn("Participant removal live projection failed after commit", { chatId: input.chatId, error })
      await pushChatCatchupHintsBestEffort({ chatId: input.chatId, currentUserId: context.currentUserId, updateSeq: update.seq })
    }
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
  const { update, affectedUserIds, accessUpdates, permissionUpdates } = await retryParticipantMutation(() => db.transaction(
    async (tx): Promise<{
      update: UpdateSeqAndDate
      affectedUserIds: number[]
      accessUpdates: { userId: number; chatId: number; update: UpdateSeqAndDate }[]
      permissionUpdates: PreparedChatPermissionUpdate[]
    }> => {
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

      const affectedUserIds = await loadActiveGroupMemberIds(input.groupId, tx)
      const accessEventChatIds = await getRootChatIdsForAccessEvents(tx, [input.chatId])
      const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)

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

      const accessAfter = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)
      const transitions = accessEventChatIds.flatMap((affectedChatId) => {
        const lostAccess = new Set(removedAccessUserIds(affectedChatId, accessBefore, accessAfter))
        return affectedUserIds
          .filter((userId) => lostAccess.has(userId))
          .map((userId) => ({ userId, chatId: affectedChatId }))
      })
      const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
        transitions.map((transition) => ({
          userId: transition.userId,
          update: {
            oneofKind: "userRemovedFromChat" as const,
            userRemovedFromChat: {
              chatId: BigInt(transition.chatId),
              groupId: transition.chatId === input.chatId ? BigInt(input.groupId) : undefined,
            },
          },
        })),
        { tx },
      )
      const accessUpdates = transitions.map((transition, index) => ({
        ...transition,
        update: persistedAccessUpdates[index]!,
      }))
      const permissionUpdates = await prepareChatPermissionUpdates(
        { userIds: affectedUserIds, chatIds: [input.chatId] },
        { tx },
      )

      return { update, affectedUserIds, accessUpdates, permissionUpdates }
    },
  ))

  try {
    for (const accessUpdate of accessUpdates) {
      await pushUserRemovedFromChat(
        accessUpdate.userId,
        accessUpdate.chatId,
        accessUpdate.chatId === input.chatId ? input.groupId : undefined,
        accessUpdate.update,
      )
    }
    await pushChatPermissionUpdates(permissionUpdates)
    await pushGroupDeleteUpdates({ chatId: input.chatId, groupId: input.groupId, currentUserId: context.currentUserId, affectedUserIds, update })
  } catch (error) {
    Log.shared.warn("Participant group removal live projection failed after commit", { chatId: input.chatId, error })
    await pushChatCatchupHintsBestEffort({ chatId: input.chatId, currentUserId: context.currentUserId, updateSeq: update.seq })
  }
}

function pushUserRemovedFromChat(
  userId: number,
  chatId: number,
  groupId: number | undefined,
  update: UpdateSeqAndDate,
): Promise<void> {
  return pushParticipantUserUpdateBestEffort(userId, {
    seq: update.seq,
    date: encodeDateStrict(update.date),
    update: {
      oneofKind: "userRemovedFromChat",
      userRemovedFromChat: {
        chatId: BigInt(chatId),
        groupId: groupId === undefined ? undefined : BigInt(groupId),
      },
    },
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
  await Promise.all(updateGroup.userIds.map(async (updateUserId) => {
    await RealtimeUpdates.pushToUser(updateUserId, [chatParticipantDelete])

    if (updateUserId === currentUserId) {
      selfUpdates = [chatParticipantDelete]
    }
  }))

  // Send to deleted user.
  // Because they're no longer in the chat topic we still need to deliver the realtime
  // event directly (the user-bucket update handles offline sync).
  await RealtimeUpdates.pushToUser(userId, [chatParticipantDelete])

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

  await Promise.all(Array.from(targetUserIds).map(async (updateUserId) => {
    await RealtimeUpdates.pushToUser(updateUserId, [chatParticipantGroupDelete])

    if (updateUserId === currentUserId) {
      selfUpdates = [chatParticipantGroupDelete]
    }
  }))

  return { selfUpdates, updateGroup }
}
