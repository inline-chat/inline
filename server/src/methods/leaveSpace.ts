import { db } from "@in/server/db"
import { and, eq, not } from "drizzle-orm"
import { members, spaces, users, type DbMember } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"

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

  // Authorize if user is creator of space
  await Authorize.spaceMember(spaceId, context.currentUserId)

  // Leave space
  let member = await leaveSpace(spaceId, context.currentUserId)

  return {
    memberId: member.id,
    userId: member.userId,
  }
}

/// HELPER FUNCTIONS ///
const leaveSpace = async (spaceId: number, currentUserId: number): Promise<DbMember> => {
  let member = await db
    .delete(members)
    // A member
    .where(
      and(
        // With this space
        eq(members.spaceId, spaceId),
        // For our user
        eq(members.userId, currentUserId),
      ),
    )
    .returning()

  if (!member[0]) {
    throw new InlineError(InlineError.ApiError.SPACE_INVALID)
  }

  return member[0]
}
