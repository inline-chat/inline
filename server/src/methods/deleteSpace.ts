import { db } from "@in/server/db"
import { eq, inArray } from "drizzle-orm"
import { members, spaces, users } from "@in/server/db/schema"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { clearGridPresenceForSpace } from "@in/server/modules/grid/roomLifecycle"
import { notifyGridSpaceChanged } from "@in/server/modules/grid/realtime"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { Update } from "@inline-chat/protocol/core"
import { InlineError } from "@in/server/types/errors"
import { deactivateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { Log } from "@in/server/utils/log"

const log = new Log("space.deleteSpace")

export const Input = Type.Object({
  spaceId: TInputId,
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = normalizeId(input.spaceId)

  // Authorize if user is creator of space
  await Authorize.spaceCreator(spaceId, context.currentUserId)

  // Delete space
  await deleteSpace(spaceId, context.currentUserId)

  // no payload on success
  return undefined
}

/// HELPER FUNCTIONS ///
const MAX_MEMBER_SET_ATTEMPTS = 3

class SpaceMemberSetChanged extends Error {
  constructor(readonly memberUserIds: number[]) {
    super("Space member set changed while deleting")
  }
}

type RemovedSpaceMember = {
  memberId: number
  userId: number
}

const deleteSpace = async (spaceId: number, currentUserId: number) => {
  let expectedMemberUserIds = await readSpaceMemberUserIds(spaceId)
  let removedMembers: RemovedSpaceMember[] | undefined

  for (let attempt = 0; attempt < MAX_MEMBER_SET_ATTEMPTS; attempt += 1) {
    try {
      removedMembers = await db.transaction(async (tx) => {
        // Retire media in the same transaction as the Space's authority. The
        // helper takes Grid's mutation lock before touching rooms or the Space.
        await clearGridPresenceForSpace(tx, spaceId)

        // All member User buckets are mutation owners. Lock their rows in a
        // stable order before the Space and membership rows so overlapping
        // membership operations cannot allocate User sequences out of order.
        if (expectedMemberUserIds.length > 0) {
          await tx
            .select({ id: users.id })
            .from(users)
            .where(inArray(users.id, expectedMemberUserIds))
            .orderBy(users.id)
            .for("update")
        }

        const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
        if (!space || space.deleted !== null) {
          throw new InlineError(InlineError.ApiError.SPACE_INVALID)
        }
        if (space.creatorId !== currentUserId) {
          throw new InlineError(InlineError.ApiError.SPACE_CREATOR_REQUIRED)
        }

        const lockedMemberRows = await tx
          .select({ memberId: members.id, userId: members.userId })
          .from(members)
          .where(eq(members.spaceId, spaceId))
          .orderBy(members.userId)
          .for("update")
        const lockedMemberUserIds = lockedMemberRows.map((row) => row.userId)
        if (!sameIds(expectedMemberUserIds, lockedMemberUserIds)) {
          throw new SpaceMemberSetChanged(lockedMemberUserIds)
        }

        await UserBucketUpdates.enqueueMany(
          lockedMemberUserIds.map((userId) => ({
            userId,
            update: {
              oneofKind: "userSpaceMemberDelete" as const,
              userSpaceMemberDelete: { spaceId: BigInt(spaceId) },
            },
          })),
          { tx },
        )
        await tx.delete(members).where(eq(members.spaceId, spaceId))
        await tx
          .update(spaces)
          .set({
            deleted: new Date(),
            // NOTE(@mo): clear name too?
          })
          .where(eq(spaces.id, spaceId))
        return lockedMemberRows
      })
      break
    } catch (error) {
      if (!(error instanceof SpaceMemberSetChanged) || attempt + 1 === MAX_MEMBER_SET_ATTEMPTS) throw error
      expectedMemberUserIds = error.memberUserIds
    }
  }

  if (!removedMembers) throw new Error("Space deletion completed without a stable member set")
  AccessGuardsCache.resetSpaceMember(spaceId)
  await notifyGridSpaceChanged(spaceId)
  for (const removedMember of removedMembers) {
    await deactivateCommittedSpaceMembership({
      spaceId,
      userId: removedMember.userId,
      memberId: removedMember.memberId,
    }, () => {
      void RealtimeUpdates.pushToUser(
        removedMember.userId,
        [immediateSpaceEviction(spaceId, removedMember.userId)],
      ).catch((error: unknown) => {
        log.warn("Failed to publish committed Space deletion", { spaceId, userId: removedMember.userId, error })
      })
      return undefined
    }).catch((error: unknown) => {
      log.warn("Failed to verify committed Space deletion side effects", {
        spaceId,
        userId: removedMember.userId,
        error,
      })
      return false
    })
  }
}

const readSpaceMemberUserIds = async (spaceId: number): Promise<number[]> => {
  const rows = await db
    .select({ userId: members.userId })
    .from(members)
    .where(eq(members.spaceId, spaceId))
    .orderBy(members.userId)
  return rows.map((row) => row.userId)
}

const sameIds = (left: number[], right: number[]): boolean =>
  left.length === right.length && left.every((id, index) => id === right[index])

const immediateSpaceEviction = (spaceId: number, userId: number): Update => ({
  update: {
    oneofKind: "spaceMemberDelete",
    spaceMemberDelete: { spaceId: BigInt(spaceId), userId: BigInt(userId) },
  },
})
