import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { members, spaces, users, type DbMember } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import type { Update } from "@inline-chat/protocol/core"
import type { Transaction } from "@in/server/db/types"
import { deactivateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { Log } from "@in/server/utils/log"

const log = new Log("space.leaveSpace")

export const Input = Type.Object({
  spaceId: TInputId,
})

export const Response = Type.Object({
  memberId: Type.Integer(),
  userId: Type.Integer(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = normalizeId(input.spaceId)

  // Authorize if user is member of space
  await Authorize.spaceMember(spaceId, context.currentUserId)

  // Leave space
  const member = await leaveSpace(spaceId, context.currentUserId)

  return {
    memberId: member.id,
    userId: member.userId,
  }
}

/// HELPER FUNCTIONS ///
const leaveSpace = async (spaceId: number, currentUserId: number): Promise<DbMember> => {
  const { member, persisted, remainingMemberUserIds } = await db.transaction(async (tx) => {
    // User-bucket allocation serializes on the user row. Keep the established
    // user -> space -> membership order, then revalidate preflight authority
    // while all mutation owners are locked.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, currentUserId)).for("update").limit(1)

    const [space] = await tx.select().from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)
    if (!space || space.deleted !== null) {
      throw new InlineError(InlineError.ApiError.SPACE_INVALID)
    }

    const [lockedMember] = await tx
      .select()
      .from(members)
      .where(and(eq(members.spaceId, spaceId), eq(members.userId, currentUserId)))
      .for("update")
      .limit(1)
    if (!lockedMember) throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)

    const [member] = await tx
      .delete(members)
      .where(eq(members.id, lockedMember.id))
      .returning()
    if (!member) throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)

    const persisted = await persistLeaveUpdates(tx, space, currentUserId)
    const remainingMemberRows = await tx
      .select({ userId: members.userId })
      .from(members)
      .where(eq(members.spaceId, spaceId))
    const remainingMemberUserIds = remainingMemberRows.map((row) => row.userId)
    return { member, persisted, remainingMemberUserIds }
  })

  await deactivateCommittedSpaceMembership({
    spaceId,
    userId: currentUserId,
    memberId: member.id,
  }, () => {
    // Queue the socket event synchronously. The generation lock must still
    // be held at the unsequenced send point, not just at an earlier check.
    void RealtimeUpdates.pushToUser(currentUserId, [{
      update: {
        oneofKind: "spaceMemberDelete",
        spaceMemberDelete: { spaceId: BigInt(spaceId), userId: BigInt(currentUserId) },
      },
    }]).catch((error: unknown) => {
      log.warn("Failed to publish committed Space leave", { spaceId, userId: currentUserId, error })
    })
    return undefined
  }).catch((error: unknown) => {
    // The durable User update remains authoritative. A failed recheck must not
    // turn a committed leave into a retry or risk publishing a stale eviction.
    log.warn("Failed to verify committed Space leave side effects", { spaceId, userId: currentUserId, error })
    return false
  })
  pushLeaveUpdates({ spaceId, currentUserId, persisted, remainingMemberUserIds })
  return member
}

const persistLeaveUpdates = async (
  tx: Transaction,
  space: typeof spaces.$inferSelect,
  userId: number,
): Promise<UpdateSeqAndDate> => {
  const spaceUpdate: ServerUpdate["update"] = {
    oneofKind: "spaceRemoveMember",
    spaceRemoveMember: {
      spaceId: BigInt(space.id),
      userId: BigInt(userId),
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

const pushLeaveUpdates = ({
  spaceId,
  currentUserId,
  persisted,
  remainingMemberUserIds,
}: {
  spaceId: number
  currentUserId: number
  persisted: UpdateSeqAndDate
  remainingMemberUserIds: number[]
}) => {
  const sequencedRemoval: Update = {
    seq: persisted.seq,
    date: encodeDateStrict(persisted.date),
    update: {
      oneofKind: "spaceMemberDelete",
      spaceMemberDelete: { spaceId: BigInt(spaceId), userId: BigInt(currentUserId) },
    },
  }
  remainingMemberUserIds.forEach((userId) => {
    void RealtimeUpdates.pushToUser(userId, [sequencedRemoval]).catch((error: unknown) => {
      log.warn("Failed to publish committed Space leave", { spaceId, userId, error })
    })
  })
}
