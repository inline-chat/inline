import { db } from "@in/server/db"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import {
  members,
  spaces,
  spaceJoinBlocks,
  userNotDeleted,
  users,
  type DbMember,
  type DbSpace,
  type DbUser,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import {
  addedAccessUserIds,
  getEffectiveChatAccessUserIds,
  getSpaceRootChatIdsForAccessEvents,
} from "@in/server/modules/authorization/chatAccessProjection"
import { activateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import {
  persistPrimarySpaceChatOpenProjectionInTransaction,
  liveUpdateForPersistedUserChatOpenProjection,
  type PersistedUserChatOpenProjection,
} from "@in/server/modules/updates/userChatOpenProjection"
import type { ServerUpdate } from "@in/server/protocol/server"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import type { Member, Space, Update } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"

const log = new Log("space.joinByLink")

type JoinOutcome = {
  space: DbSpace
  member: DbMember
  alreadyMember: boolean
  user?: DbUser
  userUpdate?: UpdateSeqAndDate
  spaceUpdate?: UpdateSeqAndDate
  accessUpdates?: Array<{ chatId: number; update: UpdateSeqAndDate }>
  chatOpen?: PersistedUserChatOpenProjection
  spaceRecipientUserIds?: number[]
}

export type SpaceLinkJoinResult = {
  space: Space
  member: Member
  alreadyMember: boolean
}

export const joinSpaceByResolvedLink = async ({
  currentUserId,
  resolveLockedSpace,
}: {
  currentUserId: number
  resolveLockedSpace: (tx: Transaction) => Promise<DbSpace | undefined>
}): Promise<SpaceLinkJoinResult> => {
  const outcome = await db.transaction(async (tx): Promise<JoinOutcome> => {
    const [user] = await tx
      .select()
      .from(users)
      .where(eq(users.id, currentUserId))
      .for("update")
      .limit(1)
    if (!user || user.deleted === true) {
      throw RealtimeRpcError.UserIdInvalid()
    }

    const space = await resolveLockedSpace(tx)
    if (!space) {
      throw RealtimeRpcError.SpaceInviteInvalid()
    }

    const [existingMember] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, currentUserId)))
      .limit(1)
    if (existingMember) {
      const chatOpen = await persistPrimarySpaceChatOpenProjectionInTransaction(tx, {
        spaceId: space.id,
        userId: currentUserId,
        canAccessPublicChats: existingMember.canAccessPublicChats !== false,
      })
      return { space, member: existingMember, alreadyMember: true, chatOpen: chatOpen ?? undefined }
    }

    const [joinBlock] = await tx
      .select({ spaceId: spaceJoinBlocks.spaceId })
      .from(spaceJoinBlocks)
      .where(and(eq(spaceJoinBlocks.spaceId, space.id), eq(spaceJoinBlocks.userId, currentUserId)))
      .limit(1)
    if (joinBlock) {
      throw RealtimeRpcError.SpaceInviteInvalid()
    }

    const affectedChatIds = await getSpaceRootChatIdsForAccessEvents(tx, space.id)
    const accessBefore = await getEffectiveChatAccessUserIds(tx, affectedChatIds, { userIds: [currentUserId] })

    const [member] = await tx
      .insert(members)
      .values({
        spaceId: space.id,
        userId: currentUserId,
        role: "member",
        canAccessPublicChats: true,
      })
      .returning()
    if (!member) {
      throw RealtimeRpcError.InternalError()
    }

    const encodedUser = space.isPublic
      ? encodePublicUser({ user })
      : Encoders.user({ user, min: false })
    const spaceUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(member),
        user: encodedUser,
      },
    }
    const spaceUpdate = await UpdatesModel.insertUpdate(tx, {
      update: spaceUpdatePayload,
      bucket: UpdateBucket.Space,
      entity: space,
    })
    await tx
      .update(spaces)
      .set({ updateSeq: spaceUpdate.seq, lastUpdateDate: spaceUpdate.date })
      .where(eq(spaces.id, space.id))
    const updatedSpace = { ...space, updateSeq: spaceUpdate.seq, lastUpdateDate: spaceUpdate.date }

    const userUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "userJoinSpace",
      userJoinSpace: {
        space: Encoders.space(updatedSpace, { encodingForUserId: currentUserId }),
        member: Encoders.member(member),
      },
    }
    const userUpdate = await UserBucketUpdates.enqueue(
      { userId: currentUserId, update: userUpdatePayload },
      { tx },
    )

    const accessAfter = await getEffectiveChatAccessUserIds(tx, affectedChatIds, { userIds: [currentUserId] })
    const gainedChatIds = affectedChatIds.filter((chatId) =>
      addedAccessUserIds(chatId, accessBefore, accessAfter).includes(currentUserId),
    )
    const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
      gainedChatIds.map((chatId) => ({
        userId: currentUserId,
        update: {
          oneofKind: "userAddedToChat" as const,
          userAddedToChat: { chatId: BigInt(chatId) },
        },
      })),
      { tx },
    )
    const accessUpdates = gainedChatIds.map((chatId, index) => ({
      chatId,
      update: persistedAccessUpdates[index]!,
    }))

    const chatOpen = await persistPrimarySpaceChatOpenProjectionInTransaction(tx, {
      spaceId: space.id,
      userId: currentUserId,
      canAccessPublicChats: member.canAccessPublicChats !== false,
      persistWhenUnchanged: true,
    })

    const recipients = await tx
      .select({ userId: members.userId })
      .from(members)
      .innerJoin(users, eq(users.id, members.userId))
      .where(and(eq(members.spaceId, space.id), userNotDeleted()))
      .orderBy(members.userId)

    return {
      space: updatedSpace,
      member,
      alreadyMember: false,
      user,
      userUpdate,
      spaceUpdate,
      accessUpdates,
      chatOpen: chatOpen ?? undefined,
      spaceRecipientUserIds: recipients.map((recipient) => recipient.userId),
    }
  })

  let activated = false
  try {
    activated = await activateCommittedSpaceMembership({
      spaceId: outcome.space.id,
      userId: currentUserId,
      memberId: outcome.member.id,
    }, () => {
      if (!outcome.alreadyMember && outcome.user && outcome.userUpdate && outcome.spaceUpdate) {
        pushJoinUpdate(outcome, currentUserId)
        pushAccessUpdates(outcome, currentUserId)
        pushSpaceMemberUpdate(outcome, [currentUserId])
      }
      if (outcome.chatOpen) {
        void RealtimeUpdates.pushToUser(
          currentUserId,
          [liveUpdateForPersistedUserChatOpenProjection(outcome.chatOpen)],
        ).catch(logFanoutFailure)
      }
      return undefined
    })
  } catch (error: unknown) {
    log.error("Failed to activate committed space-link membership", {
      spaceId: outcome.space.id,
      userId: currentUserId,
      memberId: outcome.member.id,
      error,
    })
  }

  if (activated && !outcome.alreadyMember) {
    pushSpaceMemberUpdate(outcome, (outcome.spaceRecipientUserIds ?? []).filter((userId) => userId !== currentUserId))
  }

  return {
    space: Encoders.space(outcome.space, { encodingForUserId: currentUserId }),
    member: Encoders.member(outcome.member),
    alreadyMember: outcome.alreadyMember,
  }
}

function pushAccessUpdates(outcome: JoinOutcome, userId: number): void {
  for (const accessUpdate of outcome.accessUpdates ?? []) {
    void RealtimeUpdates.pushToUser(userId, [{
      seq: accessUpdate.update.seq,
      date: encodeDateStrict(accessUpdate.update.date),
      update: {
        oneofKind: "userAddedToChat",
        userAddedToChat: { chatId: BigInt(accessUpdate.chatId) },
      },
    }]).catch(logFanoutFailure)
  }
}

function pushJoinUpdate(outcome: JoinOutcome, userId: number): void {
  if (!outcome.userUpdate) return
  const update: Update = {
    seq: outcome.userUpdate.seq,
    date: encodeDateStrict(outcome.userUpdate.date),
    update: {
      oneofKind: "joinSpace",
      joinSpace: {
        space: Encoders.space(outcome.space, { encodingForUserId: userId }),
        member: Encoders.member(outcome.member),
      },
    },
  }
  void RealtimeUpdates.pushToUser(userId, [update]).catch(logFanoutFailure)
}

function pushSpaceMemberUpdate(outcome: JoinOutcome, recipientUserIds: number[]): void {
  if (!outcome.user || !outcome.spaceUpdate) return
  const user = outcome.space.isPublic
    ? encodePublicUser({ user: outcome.user })
    : Encoders.user({ user: outcome.user, min: false })
  const update: Update = {
    seq: outcome.spaceUpdate.seq,
    date: encodeDateStrict(outcome.spaceUpdate.date),
    update: {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(outcome.member),
        user,
      },
    },
  }
  for (const userId of recipientUserIds) {
    void RealtimeUpdates.pushToUser(userId, [update]).catch(logFanoutFailure)
  }
}

function logFanoutFailure(error: unknown): void {
  log.warn("Failed to publish committed space-link update", { error })
}
