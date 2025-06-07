// Note:Mostly AI generated

import { eq, and } from "drizzle-orm"
import { db } from "@in/server/db"
import { members, type DbMember, type DbMemberRole } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { SpaceModel } from "./spaces"

const log = new Log("MembersModel")

export const MembersModel = {
  getMemberByUserId,
  getMemberById,
  createMember,
  addMemberToSpace,
  isUserMemberOfSpace,
  getAllMembersOfSpace,
  removeMemberFromSpace,
}

/**
 * Get a member by user id and space id
 *
 * @param spaceId - The id of the space
 * @param userId - The id of the user
 * @returns The member
 */
async function getMemberByUserId(spaceId: number, userId: number): Promise<DbMember | undefined> {
  const member = await db._query.members.findFirst({
    where: and(eq(members.spaceId, spaceId), eq(members.userId, userId)),
  })

  return member
}

async function getMemberById(id: number): Promise<DbMember | undefined> {
  const member = await db._query.members.findFirst({
    where: eq(members.id, id),
  })

  return member
}

/**
 * Create a member
 * @param spaceId - The id of the space
 * @param userId - The id of the user
 * @param role - The role of the member
 * @param moreInput - Additional input
 * @returns The created member
 */
async function createMember(
  spaceId: number,
  userId: number,
  role: DbMemberRole,
  moreInput: { invitedBy?: number } = {},
): Promise<DbMember> {
  const newMember = await db
    .insert(members)
    .values({
      spaceId,
      userId,
      role,
      invitedBy: moreInput.invitedBy,
    })
    .returning()

  if (!newMember[0]) {
    throw new Error("Failed to create member")
  }

  return newMember[0]
}

/**
 * Add a member to a space with proper validation
 * @param spaceId - The id of the space
 * @param userId - The id of the user to add
 * @param role - The role to assign to the member
 * @param options - Additional options
 * @returns The created member
 */
async function addMemberToSpace(
  spaceId: number,
  userId: number,
  role: DbMemberRole = "member",
  options: {
    invitedBy?: number
    skipValidation?: boolean
    allowDuplicates?: boolean
  } = {},
): Promise<DbMember> {
  if (!options.skipValidation) {
    // Validate that the space exists
    const space = await SpaceModel.getSpaceById(spaceId)
    if (!space) {
      log.error("Attempted to add member to non-existent space", { spaceId, userId })
      throw RealtimeRpcError.SpaceIdInvalid
    }

    // Check if user is already a member (unless explicitly allowing duplicates)
    if (!options.allowDuplicates) {
      const existingMember = await getMemberByUserId(spaceId, userId)
      if (existingMember) {
        log.warn("User is already a member of the space", { spaceId, userId })
        throw RealtimeRpcError.UserAlreadyMember
      }
    }
  }

  try {
    const newMember = await createMember(spaceId, userId, role, {
      invitedBy: options.invitedBy,
    })

    log.info("Successfully added member to space", {
      spaceId,
      userId,
      role,
      memberId: newMember.id,
    })

    return newMember
  } catch (error) {
    log.error("Failed to add member to space", { spaceId, userId, role, error })
    throw RealtimeRpcError.InternalError
  }
}

/**
 * Check if a user is a member of a space
 * @param spaceId - The id of the space
 * @param userId - The id of the user
 * @returns True if the user is a member, false otherwise
 */
async function isUserMemberOfSpace(spaceId: number, userId: number): Promise<boolean> {
  const member = await getMemberByUserId(spaceId, userId)
  return !!member
}

/**
 * Get all members of a space
 * @param spaceId - The id of the space
 * @returns Array of members
 */
async function getAllMembersOfSpace(spaceId: number): Promise<DbMember[]> {
  const spaceMembers = await db._query.members.findMany({
    where: eq(members.spaceId, spaceId),
  })

  return spaceMembers
}

/**
 * Remove a member from a space
 * @param spaceId - The id of the space
 * @param userId - The id of the user to remove
 * @returns True if member was removed, false if they weren't a member
 */
async function removeMemberFromSpace(spaceId: number, userId: number): Promise<boolean> {
  const result = await db
    .delete(members)
    .where(and(eq(members.spaceId, spaceId), eq(members.userId, userId)))
    .returning()

  const removed = result.length > 0

  if (removed) {
    log.info("Successfully removed member from space", { spaceId, userId })
  } else {
    log.warn("Attempted to remove non-existent member from space", { spaceId, userId })
  }

  return removed
}
