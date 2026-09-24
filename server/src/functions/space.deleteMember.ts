import { members, spaces, spaceJoinBlocks, userNotDeleted, users } from "@in/server/db/schema"
import { chatParticipants, chats } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { userGroupMembers, userGroups } from "@in/server/db/schema/userGroups"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"

import { DeleteMemberInput, Update } from "@inline-chat/protocol/core"
import { isValidSpaceId } from "@in/server/utils/validate"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Log } from "@in/server/utils/log"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Effect } from "effect"
import { SpaceIdInvalidError, SpaceNotExistsError } from "@in/server/functions/_errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { db } from "@in/server/db"
import { MemberNotExistsError } from "@in/server/modules/effect/commonErrors"
import { and, eq, inArray } from "drizzle-orm"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { publishGridMemberAccessRevoked } from "@in/server/modules/grid/accessLifecycle"
import {
  removeGridMemberPresenceInTransaction,
  type GridPresenceRemovalState,
} from "@in/server/modules/grid/roomLifecycle"
import { deactivateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { publishAccessChanged } from "@in/server/modules/cache/cluster"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { notifyGridChanged } from "@in/server/modules/grid/realtime"
import type { Transaction } from "@in/server/db/types"
import {
  getEffectiveChatAccessUserIds,
  getSpaceRootChatIdsForAccessEvents,
  removedAccessUserIds,
} from "@in/server/modules/authorization/chatAccessProjection"

const log = new Log("space.removeMember")

/**
 * Delete a member from a space
 * @param input - The input
 * @param context - The function context
 * @returns The result
 */
export const deleteMember = (input: DeleteMemberInput, context: FunctionContext) =>
  Effect.gen(function* () {
    const spaceId = Number(input.spaceId)
    if (!isValidSpaceId(spaceId)) {
      return yield* Effect.fail(new SpaceIdInvalidError())
    }

    const userId = Number(input.userId)
    if (!Number.isSafeInteger(userId) || userId <= 0) {
      return yield* Effect.fail(new MemberNotExistsError())
    }

    // Get space
    const space = yield* Effect.tryPromise({
      try: () => SpaceModel.getSpaceById(spaceId),
      catch: () => new SpaceNotExistsError(),
    })

    if (!space) {
      return yield* Effect.fail(new SpaceNotExistsError())
    }

    log.debug("Deleting member", { spaceId, userId, currentUserId: context.currentUserId })

    // Membership and Grid media authority are one durable state transition.
    // Provider revocation is inserted into the outbox before this commits.
    const { gridRemovalState, persisted, accessUpdates, remainingMemberUserIds, removedMemberId } = yield* Effect.tryPromise({
      try: () => removeMemberAndGridPresence(spaceId, userId, context.currentUserId, input.blockJoin),
      catch: (error) =>
        error instanceof MemberNotExistsError
          ? error
          : error instanceof Error
            ? error
            : new Error("removeMemberAndGridPresence failed"),
    })
    yield* Effect.sync(() => {
      publishAccessChanged({ kind: "space", spaceId }, userId)
      publishDurableReference({ bucket: { kind: "space", spaceId }, frontier: persisted.seq })
    })
    yield* Effect.promise(() =>
      deactivateCommittedSpaceMembership({ spaceId, userId, memberId: removedMemberId }, () => {
        // These functions queue their socket events synchronously, before their
        // returned promises settle. Never add an await before this eviction:
        // the lifecycle helper still owns the membership/re-add boundary here.
        void publishGridMemberAccessRevoked(spaceId, userId)
        void RealtimeUpdates.pushToUser(
          userId,
          [immediateMemberEviction(spaceId, userId, removedMemberId)],
        ).catch((error: unknown) => {
          log.warn("Failed to publish committed member eviction", { spaceId, userId, error })
        })
        return undefined
      }).catch((error: unknown) => {
        log.warn("Failed to verify committed member-removal side effects", { spaceId, userId, error })
        return false
      }),
    )
    yield* Effect.promise(() => notifyGridChanged(gridRemovalState))

    // Push updates
    const { updates } = yield* Effect.promise(() =>
      pushUpdatesForSpace({
        spaceId,
        userId,
        memberId: removedMemberId,
        currentUserId: context.currentUserId,
        persisted,
        remainingMemberUserIds,
      }),
    )
    for (const accessUpdate of accessUpdates) {
      void RealtimeUpdates.pushToUser(userId, [{
        seq: accessUpdate.update.seq,
        date: encodeDateStrict(accessUpdate.update.date),
        update: {
          oneofKind: "userRemovedFromChat",
          userRemovedFromChat: { chatId: BigInt(accessUpdate.chatId) },
        },
      }]).catch((error: unknown) => {
        log.warn("Failed to publish committed chat-access removal", { spaceId, userId, error })
      })
    }

    // Return result
    return {
      result: { updates },
    }
  })

async function removeMemberAndGridPresence(
  spaceId: number,
  userId: number,
  currentUserId: number,
  blockJoin: boolean,
): Promise<{
  gridRemovalState: GridPresenceRemovalState
  persisted: UpdateSeqAndDate
  accessUpdates: { chatId: number; update: UpdateSeqAndDate }[]
  remainingMemberUserIds: number[]
  removedMemberId: number
}> {
  return db.transaction(async (tx) => {
    // Grid mutations use the process-wide advisory lock as their owner. Take
    // it before the space row so this transaction keeps the existing lock
    // order used by Grid settings/room mutations.
    const gridRemovalState = await removeGridMemberPresenceInTransaction(tx, spaceId, userId)

    // User-bucket allocation and dialog mutations both serialize on the user
    // row. Acquire it before the space/dialog rows so this path follows the
    // existing users -> dialogs and users -> space owners without creating a
    // cycle. Keep this after the Grid advisory lock: Grid mutations already
    // use advisory -> users and must not acquire those owners in reverse.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)

    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
    if (!space || space.deleted !== null) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.SPACE_ID_INVALID, "Space not found", 404)
    }

    const [actorMembership] = await tx
      .select({ role: members.role })
      .from(members)
      .where(
        and(
          eq(members.spaceId, spaceId),
          eq(members.userId, currentUserId),
          inArray(members.role, ["admin", "owner"]),
        ),
      )
      .for("update")
      .limit(1)
    if (!actorMembership) {
      throw RealtimeRpcError.SpaceAdminRequired()
    }

    const accessEventChatIds = await getSpaceRootChatIdsForAccessEvents(tx, spaceId)
    const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds, { userIds: [userId] })

    const removed = await tx
      .delete(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
      .returning({ id: members.id })

    const removedMember = removed[0]
    if (!removedMember) throw new MemberNotExistsError()

    if (space.isPublic || blockJoin) {
      await tx
        .insert(spaceJoinBlocks)
        .values({ spaceId, userId })
        .onConflictDoNothing()
    } else {
      await tx
        .delete(spaceJoinBlocks)
        .where(and(eq(spaceJoinBlocks.spaceId, spaceId), eq(spaceJoinBlocks.userId, userId)))
    }

    // Keep all membership-owned cleanup in the same transaction as the
    // membership delete. A re-add on another connection must wait for this
    // transaction to commit, otherwise it can be followed by cleanup that
    // removes the new member's rows.
    await tx
      .delete(chatParticipants)
      .where(
        and(
          eq(chatParticipants.userId, userId),
          inArray(
            chatParticipants.chatId,
            tx.select({ id: chats.id }).from(chats).where(eq(chats.spaceId, spaceId)),
          ),
        ),
      )

    await tx
      .delete(userGroupMembers)
      .where(
        and(
          eq(userGroupMembers.userId, userId),
          inArray(
            userGroupMembers.groupId,
            tx.select({ id: userGroups.id }).from(userGroups).where(eq(userGroups.spaceId, spaceId)),
          ),
        ),
      )

    await tx.delete(dialogs).where(and(eq(dialogs.spaceId, spaceId), eq(dialogs.userId, userId)))

    const persisted = await persistSpaceMemberDeleteUpdateInTransaction(tx, space, userId, removedMember.id)
    const accessAfter = await getEffectiveChatAccessUserIds(tx, accessEventChatIds, { userIds: [userId] })
    const lostChatIds = accessEventChatIds.filter((chatId) =>
      removedAccessUserIds(chatId, accessBefore, accessAfter).includes(userId),
    )
    const userAccessUpdates = await UserBucketUpdates.enqueueMany(
      lostChatIds.map((chatId) => ({
        userId,
        update: {
          oneofKind: "userRemovedFromChat" as const,
          userRemovedFromChat: { chatId: BigInt(chatId) },
        },
      })),
      { tx },
    )
    const accessUpdates = lostChatIds.map((chatId, index) => ({
      chatId,
      update: userAccessUpdates[index]!,
    }))
    // Capture the positive Space-update recipients while the membership delete
    // and Space row lock are still owned by this transaction. A re-add after
    // commit must not make the formerly removed user eligible for this sequence.
    const remainingMemberRows = await tx
      .select({ userId: members.userId })
      .from(members)
      .innerJoin(users, eq(users.id, members.userId))
      .where(and(eq(members.spaceId, spaceId), userNotDeleted()))
    const remainingMemberUserIds = remainingMemberRows
      .map((member) => member.userId)
      .filter((remainingUserId) => remainingUserId !== userId)
    return { gridRemovalState, persisted, accessUpdates, remainingMemberUserIds, removedMemberId: removedMember.id }
  })
}

// ------------------------------------------------------------
// Updates

const pushUpdatesForSpace = async ({
  spaceId,
  userId,
  memberId,
  currentUserId,
  persisted,
  remainingMemberUserIds,
}: {
  spaceId: number
  userId: number
  memberId: number
  currentUserId: number
  persisted: UpdateSeqAndDate
  remainingMemberUserIds: number[]
}) => {
  const sequencedSpaceUpdate: Update = {
    seq: persisted.seq,
    date: encodeDateStrict(persisted.date),
    update: {
      oneofKind: "spaceMemberDelete",
      spaceMemberDelete: {
        spaceId: BigInt(spaceId),
        userId: BigInt(userId),
        memberId: BigInt(memberId),
      },
    },
  }

  remainingMemberUserIds.forEach((remainingUserId) => {
    void RealtimeUpdates.pushToUser(remainingUserId, [sequencedSpaceUpdate]).catch((error: unknown) => {
      log.warn("Failed to publish committed Space member removal", { spaceId, userId: remainingUserId, error })
    })
  })

  // The removed user's immediate eviction was queued while the generation was
  // locked. Do not repeat it in an RPC reply that can arrive after a re-add, or
  // attach a Space sequence that the removed user can no longer catch up.
  return {
    updates: currentUserId === userId ? [] : [sequencedSpaceUpdate],
  }
}

const immediateMemberEviction = (spaceId: number, userId: number, memberId: number): Update => ({
  update: {
    oneofKind: "spaceMemberDelete",
    spaceMemberDelete: {
      spaceId: BigInt(spaceId),
      userId: BigInt(userId),
      memberId: BigInt(memberId),
    },
  },
})

const persistSpaceMemberDeleteUpdateInTransaction = async (
  tx: Transaction,
  space: typeof spaces.$inferSelect,
  userId: number,
  memberId: number,
): Promise<UpdateSeqAndDate> => {
  const spaceServerUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "spaceRemoveMember",
    spaceRemoveMember: {
      spaceId: BigInt(space.id),
      userId: BigInt(userId),
      memberId: BigInt(memberId),
    },
  }

  const userServerUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "userSpaceMemberDelete",
    userSpaceMemberDelete: {
      spaceId: BigInt(space.id),
    },
  }

  const update = await UpdatesModel.insertUpdate(tx, {
    update: spaceServerUpdatePayload,
    bucket: UpdateBucket.Space,
    entity: space,
  })

  await tx
    .update(spaces)
    .set({
      updateSeq: update.seq,
      lastUpdateDate: update.date,
    })
    .where(eq(spaces.id, space.id))

  await UserBucketUpdates.enqueue(
    {
      userId,
      update: userServerUpdatePayload,
    },
    { tx },
  )

  return update
}
