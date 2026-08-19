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
    const { gridRemovalState, privateThreadIds, persisted } = yield* Effect.tryPromise({
      try: () => removeMemberAndGridPresence(spaceId, userId, context.currentUserId),
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

    privateThreadIds.forEach((chatId) => AccessGuardsCache.resetChatParticipant(chatId, userId))
    AccessGuardsCache.resetForUser(userId)

    // Push updates
    const { updates } = yield* Effect.promise(() =>
      pushUpdatesForSpace({ spaceId, userId, currentUserId: context.currentUserId, persisted }),
    )

    // Return result
    return {
      result: { updates },
    }
  })

async function removeMemberAndGridPresence(
  spaceId: number,
  userId: number,
  currentUserId: number,
): Promise<{
  gridRemovalState: GridPresenceRemovalState
  privateThreadIds: number[]
  persisted: UpdateSeqAndDate
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

    const removed = await tx
      .delete(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
      .returning({ id: members.id })

    if (removed.length === 0) throw new MemberNotExistsError()
    // Keep all membership-owned cleanup in the same transaction as the
    // membership delete. A re-add on another connection must wait for this
    // transaction to commit, otherwise it can be followed by cleanup that
    // removes the new member's rows.
    const privateThreads = await tx
      .select({ chatId: chats.id })
      .from(chats)
      .innerJoin(chatParticipants, eq(chatParticipants.chatId, chats.id))
      .where(
        and(
          eq(chats.spaceId, spaceId),
          eq(chats.type, "thread"),
          eq(chats.publicThread, false),
          eq(chatParticipants.userId, userId),
        ),
      )
    const privateThreadIds = privateThreads.map((thread) => thread.chatId)

    if (privateThreadIds.length > 0) {
      await tx
        .delete(chatParticipants)
        .where(and(eq(chatParticipants.userId, userId), inArray(chatParticipants.chatId, privateThreadIds)))
    }

    const groups = await tx.select({ groupId: userGroups.id }).from(userGroups).where(eq(userGroups.spaceId, spaceId))
    const groupIds = groups.map((group) => group.groupId)
    if (groupIds.length > 0) {
      await tx
        .delete(userGroupMembers)
        .where(and(eq(userGroupMembers.userId, userId), inArray(userGroupMembers.groupId, groupIds)))
    }

    await tx.delete(dialogs).where(and(eq(dialogs.spaceId, spaceId), eq(dialogs.userId, userId)))

    const persisted = await persistSpaceMemberDeleteUpdateInTransaction(tx, space, userId)
    return { gridRemovalState, privateThreadIds, persisted }
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
