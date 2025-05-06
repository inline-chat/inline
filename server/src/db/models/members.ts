// Note:Mostly AI generated

import { eq, and } from "drizzle-orm"
import { db } from "@in/server/db"
import { members, type DbMember, type DbMemberRole } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"

const log = new Log("MembersModel")

export const MembersModel = {
  getMemberByUserId,
  getMemberById,
  createMember,
}

/**
 * Get a member by user id and space id
 *
 * @param spaceId - The id of the space
 * @param userId - The id of the user
 * @returns The member
 */
async function getMemberByUserId(spaceId: number, userId: number): Promise<DbMember | undefined> {
  const member = await db.query.members.findFirst({
    where: and(eq(members.spaceId, spaceId), eq(members.userId, userId)),
  })

  return member
}

async function getMemberById(id: number): Promise<DbMember | undefined> {
  const member = await db.query.members.findFirst({
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
