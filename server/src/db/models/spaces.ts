import { db } from "@in/server/db"
import { members, spaces } from "@in/server/db/schema"
import { eq, or } from "drizzle-orm"

export const getSpaceIdsForUser = async (userId: number): Promise<number[]> => {
  // Using a single query to get all spaces where user is either creator or member
  const results = await db
    .select({
      id: spaces.id,
    })
    .from(spaces)
    .leftJoin(members, eq(spaces.id, members.spaceId))
    .where(eq(members.userId, userId))

  return results.map(({ id }) => id)
}
