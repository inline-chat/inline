import { syncChatAccess } from "@in/server/modules/authorization/chatAccessSync"
import { db } from "@in/server/db"
import { members, spaceJoinBlocks, spaces, userNotDeleted, users, type DbMember, type DbSpace } from "@in/server/db/schema"
import { chatParticipants, chats } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { userGroupMembers, userGroups } from "@in/server/db/schema/userGroups"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { Transaction } from "@in/server/db/types"
import type { ServerUpdate } from "@in/server/protocol/server"
import type { Update } from "@inline-chat/protocol/core"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { publishGridMemberAccessRevoked } from "@in/server/modules/grid/accessLifecycle"
import {
  removeGridMemberPresenceInTransaction,
  type GridPresenceRemovalState,
} from "@in/server/modules/grid/roomLifecycle"
import { notifyGridChanged } from "@in/server/modules/grid/realtime"
import { deactivateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { publishAccessChanged } from "@in/server/modules/cache/cluster"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import {
  getEffectiveChatAccessUserIds,
  getSpaceRootChatIdsForAccessEvents,
  removedAccessUserIds,
} from "@in/server/modules/authorization/chatAccessProjection"
import { and, eq, inArray } from "drizzle-orm"
import { Log } from "@in/server/utils/log"

const log = new Log("space.memberRemoval")

export type SpaceMemberRemovalAuthority = {
  space: DbSpace
  /** The departing user's locked role, or undefined when they are not a member. */
  targetRole: DbMember["role"] | undefined
}

export type RemoveSpaceMemberInput = {
  spaceId: number
  userId: number
  /**
   * Runs once every mutation owner is locked and before anything is deleted.
   * Throw to abort the removal.
   */
  authorize?: (tx: Transaction, authority: SpaceMemberRemovalAuthority) => Promise<void>
  /**
   * Removal by an admin maintains the join block (always set for public
   * Spaces). Leaving passes undefined and keeps any existing block untouched.
   */
  blockJoin?: boolean
  spaceNotFound: () => Error
  memberNotFound: () => Error
}

export type RemovedSpaceMember = {
  userId: number
  memberId: number
  spaceUpdate: UpdateSeqAndDate
  accessUpdates: { chatId: number; update: UpdateSeqAndDate }[]
}

export type SpaceMemberRemoval = {
  spaceId: number
  /** The departing member first, then the bots they created. */
  removed: RemovedSpaceMember[]
  gridRemovalStates: GridPresenceRemovalState[]
  remainingMemberUserIds: number[]
}

/**
 * The one membership exit used by leaving and by admin removal. A departing
 * member loses every membership-owned row in the Space (private-thread
 * participation, dialogs, user groups, Grid presence), and the bots they
 * created leave with them, so a later rejoin starts from a clean slate.
 */
export async function removeSpaceMember(input: RemoveSpaceMemberInput): Promise<SpaceMemberRemoval> {
  const { spaceId, userId } = input
  return db.transaction(async (tx) => {
    // Grid mutations use the process-wide advisory lock as their owner. Take
    // it before user and Space rows so this keeps the established Grid
    // advisory -> users -> space -> membership lock order.
    const gridRemovalStates = [await removeGridMemberPresenceInTransaction(tx, spaceId, userId)]

    const botRows = await tx
      .select({ userId: members.userId })
      .from(members)
      .innerJoin(users, eq(users.id, members.userId))
      .where(and(eq(members.spaceId, spaceId), eq(users.bot, true), eq(users.botCreatorId, userId)))
      .orderBy(members.userId)
    const botUserIds = botRows.map((row) => row.userId).filter((botUserId) => botUserId !== userId)
    for (const botUserId of botUserIds) {
      gridRemovalStates.push(await removeGridMemberPresenceInTransaction(tx, spaceId, botUserId))
    }

    // User-bucket allocation serializes on user rows. Lock them in a stable
    // order before the Space row, matching deleteSpace's multi-user path.
    const candidateUserIds = [userId, ...botUserIds]
    await tx
      .select({ id: users.id })
      .from(users)
      .where(inArray(users.id, candidateUserIds))
      .orderBy(users.id)
      .for("update")

    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
    if (!space || space.deleted !== null) throw input.spaceNotFound()

    const lockedMembers = await tx
      .select({ id: members.id, userId: members.userId, role: members.role })
      .from(members)
      .where(and(eq(members.spaceId, spaceId), inArray(members.userId, candidateUserIds)))
      .orderBy(members.userId)
      .for("update")
    const target = lockedMembers.find((member) => member.userId === userId)

    await input.authorize?.(tx, { space, targetRole: target?.role })
    if (!target) throw input.memberNotFound()

    const removedMembers = [
      target,
      ...botUserIds.flatMap((botUserId) => lockedMembers.filter((member) => member.userId === botUserId)),
    ]
    const removedUserIds = removedMembers.map((member) => member.userId)

    const accessEventChatIds = await getSpaceRootChatIdsForAccessEvents(tx, spaceId)
    const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds, { userIds: removedUserIds })

    await tx.delete(members).where(inArray(members.id, removedMembers.map((member) => member.id)))

    if (input.blockJoin !== undefined) {
      if (space.isPublic || input.blockJoin) {
        await tx.insert(spaceJoinBlocks).values({ spaceId, userId }).onConflictDoNothing()
      } else {
        await tx
          .delete(spaceJoinBlocks)
          .where(and(eq(spaceJoinBlocks.spaceId, spaceId), eq(spaceJoinBlocks.userId, userId)))
      }
    }

    // Keep all membership-owned cleanup in the same transaction as the
    // membership delete. A re-add on another connection must wait for this
    // transaction to commit, otherwise it can be followed by cleanup that
    // removes the new member's rows.
    await tx
      .delete(chatParticipants)
      .where(
        and(
          inArray(chatParticipants.userId, removedUserIds),
          inArray(chatParticipants.chatId, tx.select({ id: chats.id }).from(chats).where(eq(chats.spaceId, spaceId))),
        ),
      )
    await tx
      .delete(userGroupMembers)
      .where(
        and(
          inArray(userGroupMembers.userId, removedUserIds),
          inArray(
            userGroupMembers.groupId,
            tx.select({ id: userGroups.id }).from(userGroups).where(eq(userGroups.spaceId, spaceId)),
          ),
        ),
      )
    await tx.delete(dialogs).where(and(eq(dialogs.spaceId, spaceId), inArray(dialogs.userId, removedUserIds)))

    let sequencedSpace = space
    const spaceUpdates: UpdateSeqAndDate[] = []
    for (const member of removedMembers) {
      const persisted = await persistSpaceMemberRemoval(tx, sequencedSpace, member.userId, member.id)
      sequencedSpace = { ...sequencedSpace, updateSeq: persisted.seq }
      spaceUpdates.push(persisted)
    }

    const accessAfter = await getEffectiveChatAccessUserIds(tx, accessEventChatIds, { userIds: removedUserIds })
    const lostAccess = removedUserIds.flatMap((removedUserId) =>
      accessEventChatIds
        .filter((chatId) => removedAccessUserIds(chatId, accessBefore, accessAfter).includes(removedUserId))
        .map((chatId) => ({ userId: removedUserId, chatId })),
    )
    const accessUpdateRows = await UserBucketUpdates.enqueueMany(
      lostAccess.map(({ userId: lostUserId, chatId }) => ({
        userId: lostUserId,
        update: {
          oneofKind: "userRemovedFromChat" as const,
          userRemovedFromChat: { chatId: BigInt(chatId) },
        },
      })),
      { tx },
    )

    // Capture the positive Space-update recipients while the membership delete
    // and Space row lock are still owned by this transaction. A re-add after
    // commit must not make a removed user eligible for these sequences.
    const remainingMemberRows = await tx
      .select({ userId: members.userId })
      .from(members)
      .innerJoin(users, eq(users.id, members.userId))
      .where(and(eq(members.spaceId, spaceId), userNotDeleted()))
    await syncChatAccess(tx, { kind: "spaces", spaceIds: [spaceId], userIds: removedUserIds })

    const removed = removedMembers.map((member, index): RemovedSpaceMember => ({
      userId: member.userId,
      memberId: member.id,
      spaceUpdate: spaceUpdates[index]!,
      accessUpdates: lostAccess.flatMap((lost, lostIndex) =>
        lost.userId === member.userId ? [{ chatId: lost.chatId, update: accessUpdateRows[lostIndex]! }] : [],
      ),
    }))
    return {
      spaceId,
      removed,
      gridRemovalStates,
      remainingMemberUserIds: remainingMemberRows
        .map((member) => member.userId)
        .filter((remainingUserId) => !removedUserIds.includes(remainingUserId)),
    }
  })
}

/** The sequenced Space updates for a committed removal, in sequence order. */
export function sequencedSpaceMemberDeletes(removal: SpaceMemberRemoval): Update[] {
  return removal.removed.map((member) => ({
    seq: member.spaceUpdate.seq,
    date: encodeDateStrict(member.spaceUpdate.date),
    update: spaceMemberDelete(removal.spaceId, member),
  }))
}

/**
 * Post-commit projection of a removal: cache invalidation, durable frontier,
 * guarded eviction of each removed user, Grid fanout, and Space fanout to the
 * members who kept access.
 */
export async function publishSpaceMemberRemoval(removal: SpaceMemberRemoval): Promise<void> {
  const { spaceId, removed } = removal
  const lastSpaceUpdate = removed.at(-1)?.spaceUpdate
  for (const member of removed) publishAccessChanged({ kind: "space", spaceId }, member.userId)
  if (lastSpaceUpdate) publishDurableReference({ bucket: { kind: "space", spaceId }, frontier: lastSpaceUpdate.seq })

  for (const member of removed) {
    await deactivateCommittedSpaceMembership({ spaceId, userId: member.userId, memberId: member.memberId }, () => {
      // These functions queue their socket events synchronously, before their
      // returned promises settle. Never add an await before this eviction:
      // the lifecycle helper still owns the membership/re-add boundary here.
      void publishGridMemberAccessRevoked(spaceId, member.userId)
      void RealtimeUpdates.pushToUser(member.userId, [{ update: spaceMemberDelete(spaceId, member) }]).catch(
        (error: unknown) => {
          log.warn("Failed to publish committed member eviction", { spaceId, userId: member.userId, error })
        },
      )
      return undefined
    }).catch((error: unknown) => {
      // The durable User update remains authoritative. A failed recheck must
      // not turn a committed removal into a retry or a stale eviction.
      log.warn("Failed to verify committed member-removal side effects", { spaceId, userId: member.userId, error })
      return false
    })
  }

  // Space-wide fanout stays outside the affected-user publication lock.
  for (const state of removal.gridRemovalStates) await notifyGridChanged(state)

  const sequenced = sequencedSpaceMemberDeletes(removal)
  for (const remainingUserId of removal.remainingMemberUserIds) {
    void RealtimeUpdates.pushToUser(remainingUserId, sequenced).catch((error: unknown) => {
      log.warn("Failed to publish committed Space member removal", { spaceId, userId: remainingUserId, error })
    })
  }

  for (const member of removed) {
    for (const accessUpdate of member.accessUpdates) {
      void RealtimeUpdates.pushToUser(member.userId, [{
        seq: accessUpdate.update.seq,
        date: encodeDateStrict(accessUpdate.update.date),
        update: {
          oneofKind: "userRemovedFromChat",
          userRemovedFromChat: { chatId: BigInt(accessUpdate.chatId) },
        },
      }]).catch((error: unknown) => {
        log.warn("Failed to publish committed chat-access removal", { spaceId, userId: member.userId, error })
      })
    }
  }
}

const spaceMemberDelete = (spaceId: number, member: RemovedSpaceMember): Update["update"] => ({
  oneofKind: "spaceMemberDelete",
  spaceMemberDelete: {
    spaceId: BigInt(spaceId),
    userId: BigInt(member.userId),
    memberId: BigInt(member.memberId),
  },
})

const persistSpaceMemberRemoval = async (
  tx: Transaction,
  space: DbSpace,
  userId: number,
  memberId: number,
): Promise<UpdateSeqAndDate> => {
  const spaceUpdate: ServerUpdate["update"] = {
    oneofKind: "spaceRemoveMember",
    spaceRemoveMember: {
      spaceId: BigInt(space.id),
      userId: BigInt(userId),
      memberId: BigInt(memberId),
    },
  }
  const persisted = await UpdatesModel.insertUpdate(tx, {
    update: spaceUpdate,
    bucket: UpdateBucket.Space,
    entity: space,
  })
  await tx
    .update(spaces)
    .set({ updateSeq: persisted.seq, lastUpdateDate: persisted.date })
    .where(eq(spaces.id, space.id))

  await UserBucketUpdates.enqueue(
    {
      userId,
      update: {
        oneofKind: "userSpaceMemberDelete",
        userSpaceMemberDelete: { spaceId: BigInt(space.id) },
      },
    },
    { tx },
  )
  return persisted
}
