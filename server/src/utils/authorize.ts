import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { spaces } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"

/** Check if user is creator of space */
const spaceCreator = async (spaceId: number, currentUserId: number) => {
  const space = await db.query.spaces.findFirst({
    where: and(eq(spaces.id, spaceId), eq(spaces.creatorId, currentUserId)),
  })

  if (space === undefined) {
    throw new InlineError(InlineError.ApiError.SPACE_CREATOR_REQUIRED)
  }

  if (space.deleted !== null) {
    throw new InlineError(InlineError.ApiError.SPACE_INVALID)
  }
}

export const Authorize = {
  spaceCreator,
}
