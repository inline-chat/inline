import { type DbMember, type DbUser } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"

import { DeleteMemberInput, Update, type InviteToSpaceInput } from "@in/protocol/core"
import { isValidSpaceId } from "@in/server/utils/validate"
import { MembersModel } from "@in/server/db/models/members"
import { ProtocolConvertors } from "@in/server/types/protocolConvertors"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Log } from "@in/server/utils/log"
import { getUpdateGroupForSpace } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { AuthorizeEffect } from "@in/server/utils/authorize.effect"
import { Effect } from "effect"
import { SpaceIdInvalidError, SpaceNotExistsError } from "@in/server/functions/_errors"

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

    // Get space
    const space = yield* Effect.tryPromise(() => SpaceModel.getSpaceById(spaceId)).pipe(
      Effect.catchAll(() => Effect.fail(new SpaceNotExistsError())),
    )

    if (!space) {
      return yield* Effect.fail(new SpaceNotExistsError())
    }

    // Validate our permission in this space and maximum role we can assign
    yield* AuthorizeEffect.spaceAdmin(spaceId, context.currentUserId)

    // Delete member
    yield* MembersModel.deleteMemberEffect(spaceId, Number(input.userId))

    // Push updates
    const { updates } = yield* Effect.promise(() =>
      pushUpdatesForSpace({ spaceId, userId: Number(input.userId), currentUserId: context.currentUserId }),
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
