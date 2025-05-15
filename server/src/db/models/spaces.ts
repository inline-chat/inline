import { db } from "@in/server/db"
import { members, spaces, type DbSpace } from "@in/server/db/schema"
import { eq, or } from "drizzle-orm"

export const SpaceModel = {
  getSpaceById,
}

/**
 * Get a space by its ID
 * @param id - The ID of the space
 * @returns The space or undefined if it doesn't exist
 */
async function getSpaceById(id: number): Promise<DbSpace | undefined> {
  const result = await db._query.spaces.findFirst({
    where: eq(spaces.id, id),
  })

  return result
}

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
