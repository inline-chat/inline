import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { chatParticipantGroups } from "@in/server/db/schema/userGroups"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import {
  ChatParticipant,
  ChatParticipantGroup,
  User,
  UserGroup,
} from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { userNotDeleted, users } from "@in/server/db/schema/users"
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
import {
  ensureCanManageChatParticipants,
  ensureUserCanParticipateInChat,
} from "@in/server/modules/authorization/spaceThreadGuards"
import {
  encodeChatParticipantGroup,
  ensureGroupCanParticipateInChat,
  loadActiveGroupMemberIds,
  loadGroupsByIdsWithUsers,
} from "@in/server/modules/userGroups"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"
import {
  addedAccessUserIds,
  getRootChatIdsForAccessEvents,
  getEffectiveChatAccessUserIds,
} from "@in/server/modules/authorization/chatAccessProjection"

type AddChatParticipantOutput = {
  participant?: ChatParticipant
  groupParticipant?: ChatParticipantGroup
  group?: UserGroup
  users: User[]
}

export async function addChatParticipant(
  input: {
    chatId: number
    userId?: number
    groupId?: number
  },
  context: FunctionContext,
): Promise<AddChatParticipantOutput> {
  try {
    const userId = input.userId
    const groupId = input.groupId
    if ((userId == null && groupId == null) || (userId != null && groupId != null)) {
      throw RealtimeRpcError.BadRequest()
    }

    if (groupId != null) {
      return addChatParticipantGroup({ chatId: input.chatId, groupId }, context)
    }
    if (userId == null) {
      throw RealtimeRpcError.BadRequest()
    }

    const result = await retryParticipantMutation(() => db.transaction(async (tx): Promise<{
      participant: ChatParticipant
      update: UpdateSeqAndDate | null
      chatSeq: number
      accessUpdates: { chatId: number; update: UpdateSeqAndDate }[]
      permissionUpdates: PreparedChatPermissionUpdate[]
    }> => {
      // Check if chat exists
      const [chat] = await tx.select().from(chats).where(eq(chats.id, input.chatId)).for("update").limit(1)

      if (!chat) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
      }

      if (chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
      }

      await ensureCanManageChatParticipants(chat, context.currentUserId)
      await ensureUserCanParticipateInChat(chat, userId)

      // Check if user exists
      const user = await tx
        .select()
        .from(users)
        .where(and(eq(users.id, userId), userNotDeleted()))
        .limit(1)
      if (!user || user.length === 0) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `User with ID ${userId} not found`, 404)
      }

      // check if user is already a participant return the participant
      const [participant] = await tx
        .select()
        .from(chatParticipants)
        .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, userId)))

      if (participant != null) {
        return {
          participant: {
            userId: BigInt(participant.userId),
            date: encodeDateStrict(participant.date),
          },
          update: null,
          chatSeq: chat.updateSeq ?? 0,
          accessUpdates: [],
          permissionUpdates: [],
        }
      }

      const accessEventChatIds = await getRootChatIdsForAccessEvents(tx, [input.chatId])
      const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)

      const [newParticipant] = await tx
        .insert(chatParticipants)
        .values({
          chatId: input.chatId,
          userId,
          date: new Date(),
        })
        .returning()
      if (!newParticipant) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create chat participant", 500)
      }

      const participantForUpdate: ChatParticipant = {
        userId: BigInt(newParticipant.userId),
        date: encodeDateStrict(newParticipant.date),
      }

      const chatServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "participantAdd",
        participantAdd: {
          chatId: BigInt(input.chatId),
          participant: participantForUpdate,
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
      const gainedChatIds = accessEventChatIds.filter((affectedChatId) =>
        addedAccessUserIds(affectedChatId, accessBefore, accessAfter).includes(userId),
      )
      const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
        gainedChatIds.map((affectedChatId) => ({
          userId,
          update: {
            oneofKind: "userAddedToChat" as const,
            userAddedToChat: {
              chatId: BigInt(affectedChatId),
              participant: affectedChatId === input.chatId ? participantForUpdate : undefined,
            },
          },
        })),
        { tx },
      )
      const accessUpdates = gainedChatIds.map((chatId, index) => ({
        chatId,
        update: persistedAccessUpdates[index]!,
      }))
      const permissionUpdates = await prepareChatPermissionUpdates(
        { userIds: [userId], chatIds: [input.chatId] },
        { tx },
      )

      return {
        participant: participantForUpdate,
        update,
        chatSeq: update.seq,
        accessUpdates,
        permissionUpdates,
      }
    }))

    try {
      AccessGuardsCache.setChatParticipant(input.chatId, userId)

      if (result.update) {
        await pushChatCatchupHintsBestEffort({
          chatId: input.chatId,
          currentUserId: context.currentUserId,
          updateSeq: result.update.seq,
        })
        for (const accessUpdate of result.accessUpdates) {
          await pushUserAddedToChat(
            userId,
            accessUpdate.chatId,
            accessUpdate.chatId === input.chatId ? result.participant : undefined,
            undefined,
            accessUpdate.update,
          )
        }
        await pushChatPermissionUpdates(result.permissionUpdates)
        const [chat] = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)
        if (chat) BotUpdateProjector.participationChanged({ botUserId: userId, chat, actorUserId: context.currentUserId, added: true })
      } else if (result.chatSeq > 0) {
        await pushChatCatchupHintsBestEffort({
          chatId: input.chatId,
          currentUserId: context.currentUserId,
          updateSeq: result.chatSeq,
        })
      }
    } catch (error) {
      // The mutation is already durable. A live projection must not turn a
      // successful add into an ambiguous failed RPC; replay owns recovery.
      Log.shared.warn("Participant live projection failed after commit", { chatId: input.chatId, error })
      await pushChatCatchupHintsBestEffort({
        chatId: input.chatId,
        currentUserId: context.currentUserId,
        updateSeq: result.chatSeq,
      })
    }

    return { participant: result.participant, users: [] }
  } catch (error) {
    Log.shared.error(`Failed to add participant to chat ${input.chatId}: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to add chat participant", 500)
  }
}

async function addChatParticipantGroup(
  input: { chatId: number; groupId: number },
  context: FunctionContext,
): Promise<AddChatParticipantOutput> {
  const result = await retryParticipantMutation(() => db.transaction(
    async (tx): Promise<{
      groupParticipant: ChatParticipantGroup
      update: UpdateSeqAndDate | null
      chatSeq: number
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

      const [existing] = await tx
        .select()
        .from(chatParticipantGroups)
        .where(and(eq(chatParticipantGroups.chatId, input.chatId), eq(chatParticipantGroups.groupId, input.groupId)))

      if (existing != null) {
        return {
          groupParticipant: encodeChatParticipantGroup(existing),
          update: null,
          chatSeq: chat.updateSeq ?? 0,
          accessUpdates: [],
          permissionUpdates: [],
        }
      }

      const accessEventChatIds = await getRootChatIdsForAccessEvents(tx, [input.chatId])
      const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)

      const [newGroupParticipant] = await tx
        .insert(chatParticipantGroups)
        .values({
          chatId: input.chatId,
          groupId: input.groupId,
          date: new Date(),
        })
        .returning()

      if (!newGroupParticipant) {
        throw RealtimeRpcError.InternalError()
      }

      const groupParticipant = encodeChatParticipantGroup(newGroupParticipant)
      const chatServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "participantGroupAdd",
        participantGroupAdd: {
          chatId: BigInt(input.chatId),
          groupParticipant,
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

      const groupMemberIds = await loadActiveGroupMemberIds(input.groupId, tx)
      const accessAfter = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)
      const transitions = accessEventChatIds.flatMap((affectedChatId) => {
        const newlyAccessible = new Set(addedAccessUserIds(affectedChatId, accessBefore, accessAfter))
        return groupMemberIds
          .filter((memberId) => newlyAccessible.has(memberId))
          .map((userId) => ({ userId, chatId: affectedChatId }))
      })
      const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
        transitions.map((transition) => ({
          userId: transition.userId,
          update: {
            oneofKind: "userAddedToChat" as const,
            userAddedToChat: {
              chatId: BigInt(transition.chatId),
              group: transition.chatId === input.chatId ? groupParticipant : undefined,
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
        { userIds: groupMemberIds, chatIds: [input.chatId] },
        { tx },
      )

      return { groupParticipant, update, chatSeq: update.seq, accessUpdates, permissionUpdates }
    },
  ))

  if (result.chatSeq > 0) {
    await pushChatCatchupHintsBestEffort({
      chatId: input.chatId,
      currentUserId: context.currentUserId,
      updateSeq: result.chatSeq,
    })
  }

  let sidecars: Awaited<ReturnType<typeof loadGroupsByIdsWithUsers>> = { groups: [], users: [] }
  try {
    sidecars = await loadGroupsByIdsWithUsers([input.groupId], context.currentUserId)
  } catch (error) {
    Log.shared.warn("Participant group dependencies unavailable after commit", {
      chatId: input.chatId,
      groupId: input.groupId,
      error,
    })
  }
  const [group] = sidecars.groups

  try {
    if (result.update) {
      for (const accessUpdate of result.accessUpdates) {
        await pushUserAddedToChat(
          accessUpdate.userId,
          accessUpdate.chatId,
          undefined,
          accessUpdate.chatId === input.chatId ? result.groupParticipant : undefined,
          accessUpdate.update,
        )
      }
      await pushChatPermissionUpdates(result.permissionUpdates)
    }
  } catch (error) {
    Log.shared.warn("Participant group live projection failed after commit", { chatId: input.chatId, error })
    await pushChatCatchupHintsBestEffort({
      chatId: input.chatId,
      currentUserId: context.currentUserId,
      updateSeq: result.chatSeq,
    })
  }

  return {
    groupParticipant: result.groupParticipant,
    group,
    users: sidecars.users,
  }
}

function pushUserAddedToChat(
  userId: number,
  chatId: number,
  participant: ChatParticipant | undefined,
  group: ChatParticipantGroup | undefined,
  update: UpdateSeqAndDate,
): Promise<void> {
  return pushParticipantUserUpdateBestEffort(userId, {
    seq: update.seq,
    date: encodeDateStrict(update.date),
    update: {
      oneofKind: "userAddedToChat",
      userAddedToChat: {
        chatId: BigInt(chatId),
        participant,
        group,
      },
    },
  })
}
