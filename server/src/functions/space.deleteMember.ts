import { spaces } from "@in/server/db/schema"
import { chatParticipants, chats } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"

import { DeleteMemberInput, Update } from "@in/protocol/core"
import { isValidSpaceId } from "@in/server/utils/validate"
import { MembersModel } from "@in/server/db/models/members"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Log } from "@in/server/utils/log"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { AuthorizeEffect } from "@in/server/utils/authorize.effect"
import { Effect } from "effect"
import { SpaceIdInvalidError, SpaceNotExistsError } from "@in/server/functions/_errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { db } from "@in/server/db"
import { MemberNotExistsError } from "@in/server/modules/effect/commonErrors"
import { and, eq, inArray } from "drizzle-orm"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

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

    // Validate our permission in this space and maximum role we can assign
    yield* AuthorizeEffect.spaceAdmin(spaceId, context.currentUserId)

    log.debug("Deleting member", { spaceId, userId, currentUserId: context.currentUserId })

    // Delete member
    yield* MembersModel.deleteMemberEffect(spaceId, userId)
    AccessGuardsCache.resetSpaceMember(spaceId, userId)

    const privateThreadIds = yield* Effect.tryPromise({
      try: () => getPrivateThreadIdsForUser({ spaceId, userId }),
      catch: (error) => (error instanceof Error ? error : new Error("getPrivateThreadIdsForUser failed")),
    })

    yield* Effect.tryPromise({
      try: () =>
        removeUserFromPrivateThreads({
          chatIds: privateThreadIds,
          userId,
        }),
      catch: (error) => (error instanceof Error ? error : new Error("removeUserFromPrivateThreads failed")),
    })
    privateThreadIds.forEach((chatId) => AccessGuardsCache.resetChatParticipant(chatId, userId))
    AccessGuardsCache.resetForUser(userId)

    yield* Effect.tryPromise({
      try: () => deleteDialogsForSpace({ spaceId, userId }),
      catch: (error) => (error instanceof Error ? error : new Error("deleteDialogsForSpace failed")),
    })

    const persisted = yield* Effect.tryPromise({
      try: () =>
        persistSpaceMemberDeleteUpdate({
          spaceId,
          userId,
        }),
      catch: (error) => (error instanceof Error ? error : new Error("persistSpaceMemberDeleteUpdate failed")),
    })

    // Push updates
    const { updates } = yield* Effect.promise(() =>
      pushUpdatesForSpace({ spaceId, userId, currentUserId: context.currentUserId, persisted }),
    )

    // Return result
    return {
      result: { updates },
    }
  })

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

const persistSpaceMemberDeleteUpdate = async ({
  spaceId,
  userId,
}: {
  spaceId: number
  userId: number
}): Promise<UpdateSeqAndDate> => {
  const spaceServerUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "spaceRemoveMember",
    spaceRemoveMember: {
      spaceId: BigInt(spaceId),
      userId: BigInt(userId),
    },
  }

  const userServerUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "userSpaceMemberDelete",
    userSpaceMemberDelete: {
      spaceId: BigInt(spaceId),
    },
  }

  const persisted = await db.transaction(async (tx): Promise<UpdateSeqAndDate> => {
    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)

    if (!space) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.SPACE_ID_INVALID, "Space not found", 404)
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
      .where(eq(spaces.id, spaceId))

    await UserBucketUpdates.enqueue(
      {
        userId,
        update: userServerUpdatePayload,
      },
      { tx },
    )

    return update
  })

  return persisted
}

// ------------------------------------------------------------
// Cleanup helpers (no realtime updates)

const getPrivateThreadIdsForUser = async ({
  spaceId,
  userId,
}: {
  spaceId: number
  userId: number
}): Promise<number[]> => {
  const threads = await db
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

  return threads.map((t) => t.chatId)
}

const removeUserFromPrivateThreads = async ({ chatIds, userId }: { chatIds: number[]; userId: number }) => {
  if (chatIds.length === 0) return

  await db
    .delete(chatParticipants)
    .where(and(eq(chatParticipants.userId, userId), inArray(chatParticipants.chatId, chatIds)))
}

const deleteDialogsForSpace = async ({ spaceId, userId }: { spaceId: number; userId: number }) => {
  await db.delete(dialogs).where(and(eq(dialogs.spaceId, spaceId), eq(dialogs.userId, userId)))
}
