import { members, spaces, users } from "@in/server/db/schema"
import { chatParticipants, chats } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { userGroupMembers, userGroups } from "@in/server/db/schema/userGroups"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"

import { DeleteMemberInput, Update } from "@inline-chat/protocol/core"
import { isValidSpaceId } from "@in/server/utils/validate"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Log } from "@in/server/utils/log"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
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
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { finishGridMemberAccess } from "@in/server/modules/grid/accessLifecycle"
import {
  removeGridMemberPresenceInTransaction,
  type GridPresenceRemovalState,
} from "@in/server/modules/grid/roomLifecycle"
import { connectionManager } from "@in/server/ws/connections"
import type { Transaction } from "@in/server/db/types"
import {
  getEffectiveChatAccessUserIds,
  getSpaceRootChatIdsForAccessEvents,
  removedAccessUserIds,
} from "@in/server/modules/authorization/chatAccessProjection"
import {
  getSyncV3UpdateProducerMode,
  type SyncV3UpdateProducerMode,
} from "@in/server/modules/serverConfig"

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
    const updateProducerMode = yield* Effect.promise(getSyncV3UpdateProducerMode)

    // Membership and Grid media authority are one durable state transition.
    // Provider revocation is inserted into the outbox before this commits.
    const { gridRemovalState, persisted, accessUpdates } = yield* Effect.tryPromise({
      try: () => removeMemberAndGridPresence(spaceId, userId, context.currentUserId, updateProducerMode),
      catch: (error) =>
        error instanceof MemberNotExistsError
          ? error
          : error instanceof Error
            ? error
            : new Error("removeMemberAndGridPresence failed"),
    })
    AccessGuardsCache.resetSpaceMember(spaceId, userId)
    connectionManager.unsubscribeUserFromSpace(userId, spaceId)

    yield* Effect.tryPromise({
      try: () => finishGridMemberAccess(gridRemovalState, spaceId, userId),
      catch: (error) => (error instanceof Error ? error : new Error("finishGridMemberAccess failed")),
    })

    AccessGuardsCache.resetForUser(userId)

    // Push updates
    const { updates } = yield* Effect.promise(() =>
      pushUpdatesForSpace({ spaceId, userId, currentUserId: context.currentUserId, persisted }),
    )
    if (updateProducerMode === "canonical_v3") {
      for (const accessUpdate of accessUpdates) {
        RealtimeUpdates.pushToUser(userId, [{
          seq: accessUpdate.update.seq,
          date: encodeDateStrict(accessUpdate.update.date),
          update: {
            oneofKind: "userRemovedFromChat",
            userRemovedFromChat: { chatId: BigInt(accessUpdate.chatId) },
          },
        }])
      }
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
  updateProducerMode: SyncV3UpdateProducerMode,
): Promise<{
  gridRemovalState: GridPresenceRemovalState
  persisted: UpdateSeqAndDate
  accessUpdates: { chatId: number; update: UpdateSeqAndDate }[]
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
    if (!space) {
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

    const accessEventChatIds = updateProducerMode === "canonical_v3"
      ? await getSpaceRootChatIdsForAccessEvents(tx, spaceId)
      : []
    const accessBefore = updateProducerMode === "canonical_v3"
      ? await getEffectiveChatAccessUserIds(tx, accessEventChatIds, { userIds: [userId] })
      : null

    const removed = await tx
      .delete(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
      .returning({ id: members.id })

    if (removed.length === 0) throw new MemberNotExistsError()
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

    const persisted = await persistSpaceMemberDeleteUpdateInTransaction(tx, space, userId)
    const accessAfter = updateProducerMode === "canonical_v3"
      ? await getEffectiveChatAccessUserIds(tx, accessEventChatIds, { userIds: [userId] })
      : null
    const lostChatIds = updateProducerMode === "canonical_v3"
      ? accessEventChatIds.filter((chatId) =>
          removedAccessUserIds(chatId, accessBefore!, accessAfter!).includes(userId),
        )
      : []
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
    return { gridRemovalState, persisted, accessUpdates }
  })
}

// ------------------------------------------------------------
// Updates

const pushUpdatesForSpace = async ({
  spaceId,
  userId,
  currentUserId,
  persisted,
}: {
  spaceId: number
  userId: number
  currentUserId: number
  persisted: UpdateSeqAndDate
}) => {
  const update: Update = {
    seq: persisted.seq,
    date: encodeDateStrict(persisted.date),
    update: {
      oneofKind: "spaceMemberDelete",
      spaceMemberDelete: {
        spaceId: BigInt(spaceId),
        userId: BigInt(userId),
      },
    },
  }

  // Update for the space
  const updateGroup = await getUpdateGroupForSpace(spaceId, { currentUserId })

  updateGroup.userIds.forEach((userId) => {
    RealtimeUpdates.pushToUser(userId, [update])
  })

  // Also push directly to the removed user. They are no longer part of the space topic,
  // but connected clients still need the realtime event even though they will only get
  // the persisted user-bucket update on the next sync.
  RealtimeUpdates.pushToUser(userId, [update])

  return { updates: [update] }
}

const persistSpaceMemberDeleteUpdateInTransaction = async (
  tx: Transaction,
  space: typeof spaces.$inferSelect,
  userId: number,
): Promise<UpdateSeqAndDate> => {
  const spaceServerUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "spaceRemoveMember",
    spaceRemoveMember: {
      spaceId: BigInt(space.id),
      userId: BigInt(userId),
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
