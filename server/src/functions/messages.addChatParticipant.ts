import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { chatParticipantGroups } from "@in/server/db/schema/userGroups"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import { ChatParticipant, ChatParticipantGroup, Update, User, UserGroup } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { userNotDeleted, users } from "@in/server/db/schema/users"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroup } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import { UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
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

    const result = await db.transaction(async (tx): Promise<{
      participant: ChatParticipant
      update: UpdateSeqAndDate | null
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
          permissionUpdates: [],
        }
      }

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

      await UserBucketUpdates.enqueue(
        {
          userId,
          update: {
            oneofKind: "userChatParticipantAdd",
            userChatParticipantAdd: {
              chatId: BigInt(input.chatId),
              participant: participantForUpdate,
            },
          },
        },
        { tx },
      )
      const permissionUpdates = await prepareChatPermissionUpdates(
        { userIds: [userId], chatIds: [input.chatId] },
        { tx },
      )

      return {
        participant: participantForUpdate,
        update,
        permissionUpdates,
      }
    })

    AccessGuardsCache.setChatParticipant(input.chatId, userId)

    if (result.update) {
      await pushUpdates({
        chatId: input.chatId,
        currentUserId: context.currentUserId,
        participant: result.participant,
        update: result.update,
      })
      pushChatPermissionUpdates(result.permissionUpdates)
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
  const result = await db.transaction(
    async (tx): Promise<{
      groupParticipant: ChatParticipantGroup
      update: UpdateSeqAndDate | null
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
          permissionUpdates: [],
        }
      }

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

      const groupMemberIds = await loadActiveGroupMemberIds(input.groupId)
      await Promise.all(
        groupMemberIds.map((memberId) =>
          UserBucketUpdates.enqueue(
            {
              userId: memberId,
              update: {
                oneofKind: "userChatParticipantGroupAdd",
                userChatParticipantGroupAdd: {
                  chatId: BigInt(input.chatId),
                  groupParticipant,
                },
              },
            },
            { tx },
          ),
        ),
      )
      const permissionUpdates = await prepareChatPermissionUpdates(
        { userIds: groupMemberIds, chatIds: [input.chatId] },
        { tx },
      )

      return { groupParticipant, update, permissionUpdates }
    },
  )

  const sidecars = await loadGroupsByIdsWithUsers([input.groupId], context.currentUserId)
  const [group] = sidecars.groups

  if (result.update) {
    await pushGroupUpdates({
      chatId: input.chatId,
      currentUserId: context.currentUserId,
      groupParticipant: result.groupParticipant,
      update: result.update,
    })
    pushChatPermissionUpdates(result.permissionUpdates)
  }

  return {
    groupParticipant: result.groupParticipant,
    group,
    users: sidecars.users,
  }
}

/** Push participant-add updates to currently connected clients. */
const pushUpdates = async ({
  chatId,
  currentUserId,
  participant,
  update,
}: {
  chatId: number
  currentUserId: number
  participant: ChatParticipant
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chatId }, { currentUserId })

  let selfUpdates: Update[] = []

  updateGroup.userIds.forEach((userId) => {
    const chatParticipantAdd: Update = {
      seq: update.seq,
      date: encodeDateStrict(update.date),
      update: {
        oneofKind: "participantAdd",
        participantAdd: {
          chatId: BigInt(chatId),
          participant: participant,
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [chatParticipantAdd])

    if (userId === currentUserId) {
      selfUpdates = [chatParticipantAdd]
    }
  })

  return { selfUpdates, updateGroup }
}

/** Push group participant-add updates to currently connected clients. */
const pushGroupUpdates = async ({
  chatId,
  currentUserId,
  groupParticipant,
  update,
}: {
  chatId: number
  currentUserId: number
  groupParticipant: ChatParticipantGroup
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chatId }, { currentUserId })

  let selfUpdates: Update[] = []

  updateGroup.userIds.forEach((userId) => {
    const chatParticipantGroupAdd: Update = {
      seq: update.seq,
      date: encodeDateStrict(update.date),
      update: {
        oneofKind: "participantGroupAdd",
        participantGroupAdd: {
          chatId: BigInt(chatId),
          groupParticipant,
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [chatParticipantGroupAdd])

    if (userId === currentUserId) {
      selfUpdates = [chatParticipantGroupAdd]
    }
  })

  return { selfUpdates, updateGroup }
}
