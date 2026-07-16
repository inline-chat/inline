import { db } from "@in/server/db"
import {
  chatParticipantGroups,
  chats,
  chatParticipants,
  dialogs,
  members,
  userGroupMembers,
  userGroups,
  userNotDeleted,
  users,
  type DbChat,
  type DbChatParticipantGroup,
} from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { and, eq, inArray, isNull, notInArray, or } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { Update } from "@inline-chat/protocol/core"
import { getUpdateGroup, type UpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { Transaction } from "@in/server/db/types"
import {
  prepareChatPermissionUpdates,
  pushChatPermissionUpdates,
  type PreparedChatPermissionUpdate,
} from "@in/server/modules/authorization/chatPermissionUpdates"

const log = new Log("functions.updateChatVisibility")

type UpdateChatVisibilityInput = {
  chatId: number
  isPublic: boolean
  participants?: number[]
}

type UpdateChatVisibilityOutput = {
  chat: DbChat
  removedUserIds: number[]
  groupRevocations: GroupGrantRevocation[]
  update: UpdateSeqAndDate
  permissionUpdates: PreparedChatPermissionUpdate[]
}

type GroupGrantRevocation = {
  chatId: number
  groupId: number
  memberIds: number[]
  update: UpdateSeqAndDate
}

type GroupMemberAccess = {
  groupId: number
  userId: number
  canAccessPublicChats: boolean | null
}

type ChatUpdateCursor = {
  id: number
  updateSeq: number | null | undefined
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
  let groupRevocations: GroupGrantRevocation[] = []
  let updatedChat: DbChat | undefined
  let persistedUpdate: UpdateSeqAndDate | undefined
  let permissionUpdates: PreparedChatPermissionUpdate[] = []

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

      const existingGroupGrants = await tx
        .select()
        .from(chatParticipantGroups)
        .where(eq(chatParticipantGroups.chatId, chatId))
      const groupMemberRows = await loadActiveGroupMembers(
        tx,
        existingGroupGrants.map((grant) => grant.groupId),
      )

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
        const blockedGroupMemberIds = groupMemberRows
          .filter((row) => !row.canAccessPublicChats)
          .map((row) => row.userId)
        removedUserIds = uniqueIds([...removedUserIds, ...blockedGroupMemberIds])

        if (removedUserIds.length > 0) {
          await tx
            .delete(dialogs)
            .where(and(eq(dialogs.chatId, chatId), inArray(dialogs.userId, removedUserIds)))
        }

        await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chatId))
        await tx.delete(chatParticipantGroups).where(eq(chatParticipantGroups.chatId, chatId))
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
        await tx.delete(chatParticipantGroups).where(eq(chatParticipantGroups.chatId, chatId))

        await tx.insert(chatParticipants).values(
          uniqueParticipantIds.map((userId) => ({
            chatId,
            userId,
            date: new Date(),
          })),
        )
      }

      const chatUpdateCursor: ChatUpdateCursor = { id: chat.id, updateSeq: chat.updateSeq }
      groupRevocations = await insertGroupRevocationUpdates(tx, chatUpdateCursor, existingGroupGrants, groupMemberRows)

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
        entity: chatUpdateCursor,
      })
      chatUpdateCursor.updateSeq = update.seq

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
        [
          ...groupRevocations.flatMap((revocation) =>
            revocation.memberIds.map((userId) => ({
              userId,
              update: {
                oneofKind: "userChatParticipantGroupDelete" as const,
                userChatParticipantGroupDelete: {
                  chatId: BigInt(chat.id),
                  groupId: BigInt(revocation.groupId),
                },
              },
            })),
          ),
          ...removedUserIds.map((userId) => ({
            userId,
            update: {
              oneofKind: "userChatParticipantDelete" as const,
              userChatParticipantDelete: {
                chatId: BigInt(chat.id),
              },
            },
          })),
        ],
        { tx },
      )

      const permissionUpdates = await prepareChatPermissionUpdates(
        {
          userIds: uniqueIds([
            ...removedUserIds,
            ...groupRevocations.flatMap((revocation) => revocation.memberIds),
          ]),
          chatIds: [chat.id],
        },
        { tx },
      )

      return { chat: chatRecord, removedUserIds, groupRevocations, update, permissionUpdates }
    })

    updatedChat = result.chat
    removedUserIds = result.removedUserIds
    groupRevocations = result.groupRevocations
    persistedUpdate = result.update
    permissionUpdates = result.permissionUpdates
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
  groupRevocations.forEach((revocation) => {
    revocation.memberIds.forEach((userId) => AccessGuardsCache.resetChatParticipant(updatedChat!.id, userId))
  })

  await pushUpdates({
    chat: updatedChat,
    isPublic,
    removedUserIds,
    groupRevocations,
    currentUserId: context.currentUserId,
    update: persistedUpdate,
  })
  pushChatPermissionUpdates(permissionUpdates)

  return { chat: updatedChat }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

async function loadActiveGroupMembers(tx: Transaction, groupIds: number[]): Promise<GroupMemberAccess[]> {
  const ids = uniqueIds(groupIds)
  if (ids.length === 0) {
    return []
  }

  return tx
    .select({
      groupId: userGroupMembers.groupId,
      userId: userGroupMembers.userId,
      canAccessPublicChats: members.canAccessPublicChats,
    })
    .from(userGroupMembers)
    .innerJoin(userGroups, eq(userGroups.id, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(users, eq(users.id, userGroupMembers.userId))
    .where(and(inArray(userGroupMembers.groupId, ids), userNotDeleted()))
}

async function insertGroupRevocationUpdates(
  tx: Transaction,
  chat: ChatUpdateCursor,
  grants: DbChatParticipantGroup[],
  memberRows: GroupMemberAccess[],
): Promise<GroupGrantRevocation[]> {
  const memberIdsByGroupId = new Map<number, number[]>()
  for (const row of memberRows) {
    const memberIds = memberIdsByGroupId.get(row.groupId)
    if (memberIds) {
      memberIds.push(row.userId)
    } else {
      memberIdsByGroupId.set(row.groupId, [row.userId])
    }
  }

  const revocations: GroupGrantRevocation[] = []
  for (const grant of grants) {
    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "participantGroupDelete",
        participantGroupDelete: {
          chatId: BigInt(grant.chatId),
          groupId: BigInt(grant.groupId),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })
    chat.updateSeq = update.seq

    revocations.push({
      chatId: grant.chatId,
      groupId: grant.groupId,
      memberIds: memberIdsByGroupId.get(grant.groupId) ?? [],
      update,
    })
  }

  return revocations
}

function uniqueIds(ids: number[]): number[] {
  return Array.from(new Set(ids.filter((id) => Number.isSafeInteger(id) && id > 0)))
}

const pushUpdates = async ({
  chat,
  isPublic,
  removedUserIds,
  groupRevocations,
  currentUserId,
  update,
}: {
  chat: DbChat
  isPublic: boolean
  removedUserIds: number[]
  groupRevocations: GroupGrantRevocation[]
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chat.id }, { currentUserId })
  const updateGroupUserIds = new Set(updateGroup.userIds)
  const groupDeleteUpdates = groupRevocations.map(groupRevocationUpdate)
  const chatsByUserId = await Encoders.chatForUsers(chat, updateGroup.userIds)

  updateGroup.userIds.forEach((userId) => {
    const updates: Update[] = [
      ...groupDeleteUpdates,
      {
        update: {
          oneofKind: "newChat",
          newChat: {
            chat: chatsByUserId.get(userId),
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

  for (const revocation of groupRevocations) {
    const groupDeleteUpdate = groupRevocationUpdate(revocation)
    revocation.memberIds.forEach((userId) => {
      if (!updateGroupUserIds.has(userId)) {
        RealtimeUpdates.pushToUser(userId, [groupDeleteUpdate])
      }
    })
  }

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

function groupRevocationUpdate(revocation: GroupGrantRevocation): Update {
  return {
    seq: revocation.update.seq,
    date: encodeDateStrict(revocation.update.date),
    update: {
      oneofKind: "participantGroupDelete",
      participantGroupDelete: {
        chatId: BigInt(revocation.chatId),
        groupId: BigInt(revocation.groupId),
      },
    },
  }
}
