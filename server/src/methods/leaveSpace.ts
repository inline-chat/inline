import { members, type DbMember } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"
import { publishSpaceMemberRemoval, removeSpaceMember } from "@in/server/modules/spaces/spaceMemberRemoval"
import { and, eq, ne } from "drizzle-orm"

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
    memberId: member.memberId,
    userId: member.userId,
  }
}

/// HELPER FUNCTIONS ///
const leaveSpace = async (
  spaceId: number,
  currentUserId: number,
): Promise<{ memberId: DbMember["id"]; userId: DbMember["userId"] }> => {
  // Leaving is the same membership exit as an admin removal: it drops
  // private-thread participation, dialogs, groups, Grid presence and the
  // leaver's bots, so rejoining cannot restore stale access. Join blocks are
  // left as they are.
  const removal = await removeSpaceMember({
    spaceId,
    userId: currentUserId,
    // The last owner cannot leave: nobody else could delete the Space, and
    // owners cannot be promoted. Leaves serialize on the locked Space row, so
    // two owners leaving at once cannot both pass this check.
    authorize: async (tx, { targetRole }) => {
      if (targetRole !== "owner") return
      const [otherOwner] = await tx
        .select({ id: members.id })
        .from(members)
        .where(and(eq(members.spaceId, spaceId), eq(members.role, "owner"), ne(members.userId, currentUserId)))
        .limit(1)
      if (!otherOwner) throw new InlineError(InlineError.ApiError.SPACE_LAST_OWNER)
    },
    spaceNotFound: () => new InlineError(InlineError.ApiError.SPACE_INVALID),
    memberNotFound: () => new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT),
  })
  await publishSpaceMemberRemoval(removal)

  const [leaver] = removal.removed
  if (!leaver) throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)
  return { memberId: leaver.memberId, userId: leaver.userId }
}
