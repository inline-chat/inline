import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { members, spaces } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"

/** Check if user is creator of space */
const spaceCreator = async (spaceId: number, currentUserId: number) => {
  const space = await db.query.spaces.findFirst({
    where: and(eq(spaces.id, spaceId), eq(spaces.creatorId, currentUserId)),
  })

  // Check if space that we are trying to use as creator exists
  if (space === undefined) {
    throw new InlineError(InlineError.ApiError.SPACE_CREATOR_REQUIRED)
  }

  // Check if space is deleted, which means we can't use it
  if (space.deleted !== null) {
    throw new InlineError(InlineError.ApiError.SPACE_INVALID)
  }
}

/** Check if user is member of space */
const spaceMember = async (spaceId: number, currentUserId: number) => {
  const space = await db.query.members.findFirst({
    where: and(eq(members.spaceId, spaceId), eq(members.userId, currentUserId)),
  })

  // Check if space that we are trying to use as member exists
  if (space === undefined) {
    throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)
  }
}

export const Authorize = {
  spaceCreator,
  spaceMember,
}
