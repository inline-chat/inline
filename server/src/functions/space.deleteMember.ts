import { spaces } from "@in/server/db/schema"
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
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { db } from "@in/server/db"
import { MemberNotExistsError } from "@in/server/modules/effect/commonErrors"
import { eq } from "drizzle-orm"

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

    yield* Effect.tryPromise({
      try: () =>
        persistSpaceMemberDeleteUpdate({
          spaceId,
          userId,
        }),
      catch: (error) => (error instanceof Error ? error : new Error("persistSpaceMemberDeleteUpdate failed")),
    })

    // Push updates
    const { updates } = yield* Effect.promise(() =>
      pushUpdatesForSpace({ spaceId, userId, currentUserId: context.currentUserId }),
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
}: {
  spaceId: number
  userId: number
  currentUserId: number
}) => {
  const update: Update = {
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

  return { updates: [update] }
}

const persistSpaceMemberDeleteUpdate = async ({ spaceId, userId }: { spaceId: number; userId: number }) => {
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

  await db.transaction(async (tx) => {
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
  })
}
