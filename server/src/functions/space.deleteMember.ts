import { members, type DbMember } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"

import { DeleteMemberInput } from "@inline-chat/protocol/core"
import { isValidSpaceId } from "@in/server/utils/validate"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Log } from "@in/server/utils/log"
import { Effect } from "effect"
import { SpaceIdInvalidError, SpaceNotExistsError } from "@in/server/functions/_errors"
import { MemberNotExistsError } from "@in/server/modules/effect/commonErrors"
import { and, eq, inArray } from "drizzle-orm"
import type { Transaction } from "@in/server/db/types"
import {
  publishSpaceMemberRemoval,
  removeSpaceMember,
  sequencedSpaceMemberDeletes,
} from "@in/server/modules/spaces/spaceMemberRemoval"

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
    const removal = yield* Effect.tryPromise({
      try: () =>
        removeSpaceMember({
          spaceId,
          userId,
          blockJoin: input.blockJoin,
          authorize: (tx, { targetRole }) => authorizeMemberRemoval(tx, spaceId, context.currentUserId, targetRole),
          spaceNotFound: () => new RealtimeRpcError(RealtimeRpcError.Code.SPACE_ID_INVALID, "Space not found", 404),
          memberNotFound: () => new MemberNotExistsError(),
        }),
      catch: (error) =>
        error instanceof MemberNotExistsError
          ? error
          : error instanceof Error
            ? error
            : new Error("removeSpaceMember failed"),
    })
    yield* Effect.promise(() => publishSpaceMemberRemoval(removal))

    // The removed user's immediate eviction was queued while the generation
    // was locked. Do not repeat it in an RPC reply that can arrive after a
    // re-add, or attach a Space sequence that the removed user can no longer
    // catch up.
    return {
      result: { updates: context.currentUserId === userId ? [] : sequencedSpaceMemberDeletes(removal) },
    }
  })

/**
 * Admins and owners may remove members; only an owner may remove an owner.
 * Runs with the Space and target membership rows locked.
 */
async function authorizeMemberRemoval(
  tx: Transaction,
  spaceId: number,
  currentUserId: number,
  targetRole: DbMember["role"] | undefined,
): Promise<void> {
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
  if (targetRole === "owner" && actorMembership.role !== "owner") {
    throw RealtimeRpcError.SpaceOwnerRequired()
  }
}
