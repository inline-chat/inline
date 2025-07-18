import { db } from "@in/server/db"
import { members, spaces, type DbSpace, type DbMemberRole } from "@in/server/db/schema"
import { eq, lt, or } from "drizzle-orm"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { MembersModel } from "./members"

const log = new Log("SpaceModel")

export const SpaceModel = {
  getSpaceById,
  addUserToSpace,
  removeUserFromSpace,
  validateSpaceAccess,
  isValidSpaceId,
  getSpacesAfterUpdateDate,
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

/**
 * Add a user to a space with validation and error handling
 * @param spaceId - The ID of the space
 * @param userId - The ID of the user to add
 * @param role - The role to assign (defaults to 'member')
 * @param options - Additional options
 * @returns The created member
 */
async function addUserToSpace(
  spaceId: number,
  userId: number,
  role: DbMemberRole = "member",
  options: {
    invitedBy?: number
    skipExistingCheck?: boolean
  } = {},
): Promise<void> {
  // Validate space exists
  const space = await getSpaceById(spaceId)
  if (!space) {
    log.error("Attempted to add user to non-existent space", { spaceId, userId })
    throw RealtimeRpcError.SpaceIdInvalid
  }

  try {
    await MembersModel.addMemberToSpace(spaceId, userId, role, {
      invitedBy: options.invitedBy,
      allowDuplicates: options.skipExistingCheck,
    })

    log.info("Successfully added user to space", {
      spaceId: space.id,
      spaceName: space.name,
      userId,
      role,
    })
  } catch (error) {
    // Re-throw known errors, wrap unknown ones
    if (error === RealtimeRpcError.UserAlreadyMember || error === RealtimeRpcError.SpaceIdInvalid) {
      throw error
    }

    log.error("Failed to add user to space", { spaceId, userId, role, error })
    throw RealtimeRpcError.InternalError
  }
}

/**
 * Remove a user from a space
 * @param spaceId - The ID of the space
 * @param userId - The ID of the user to remove
 * @returns True if the user was removed, false if they weren't a member
 */
async function removeUserFromSpace(spaceId: number, userId: number): Promise<boolean> {
  const removed = await MembersModel.removeMemberFromSpace(spaceId, userId)

  if (removed) {
    log.info("User removed from space", { spaceId, userId })
  }

  return removed
}

/**
 * Validate that a space exists and optionally check user access
 * @param spaceId - The ID of the space
 * @param userId - Optional user ID to check membership
 * @returns The space if valid
 */
async function validateSpaceAccess(spaceId: number, userId?: number): Promise<DbSpace> {
  const space = await getSpaceById(spaceId)
  if (!space) {
    throw RealtimeRpcError.SpaceIdInvalid
  }

  if (userId) {
    const isMember = await MembersModel.isUserMemberOfSpace(spaceId, userId)
    if (!isMember) {
      throw RealtimeRpcError.SpaceAdminRequired // or create a new "not a member" error
    }
  }

  return space
}

/**
 * Check if a space ID is valid (exists)
 * @param spaceId - The ID to validate
 * @returns True if the space exists
 */
async function isValidSpaceId(spaceId: number): Promise<boolean> {
  if (isNaN(spaceId) || spaceId <= 0) {
    return false
  }

  const space = await getSpaceById(spaceId)
  return !!space
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

type GetSpacesAfterUpdateDateInput = {
  userId: number
  lastUpdateDateGreaterThanEqual: Date
}

/**
 * Get spaces that the user is a member of and have been updated after the last update date
 * @param input - The input object
 * @returns The spaces
 */
async function getSpacesAfterUpdateDate(input: GetSpacesAfterUpdateDateInput): Promise<DbSpace[]> {
  // Get spaces
  const result = await db.query.spaces.findMany({
    where: {
      // that are not deleted
      deleted: {
        isNull: true,
      },

      // that the user is a member of
      members: {
        userId: input.userId,
      },

      // that have been updated after the last update date
      lastUpdateDate: {
        gte: input.lastUpdateDateGreaterThanEqual,
      },
    },
  })

  return result
}
