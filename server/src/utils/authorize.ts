import { db } from "@in/server/db"
import { and, eq, inArray } from "drizzle-orm"
import { members, spaces, type DbMember, chatParticipants, integrations } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"

/**
 * Check if user is a current owner of space. Ownership is the member role,
 * not `spaces.creatorId`: a creator who left the space is no longer an owner.
 * Fails with the creator-required error that clients already handle.
 */
const spaceOwner = async (spaceId: number, currentUserId: number) => {
  const [row] = await db
    .select({ deleted: spaces.deleted })
    .from(members)
    .innerJoin(spaces, eq(spaces.id, members.spaceId))
    .where(and(eq(members.spaceId, spaceId), eq(members.userId, currentUserId), eq(members.role, "owner")))
    .limit(1)

  if (row === undefined) {
    throw new InlineError(InlineError.ApiError.SPACE_CREATOR_REQUIRED)
  }

  if (row.deleted !== null) {
    throw new InlineError(InlineError.ApiError.SPACE_INVALID)
  }
}

/** Check if user is member of space */
const spaceMember = async (spaceId: number, currentUserId: number): Promise<{ member: DbMember }> => {
  const member = await db._query.members.findFirst({
    where: and(eq(members.spaceId, spaceId), eq(members.userId, currentUserId)),
  })

  // Check if space that we are trying to use as member exists
  if (member === undefined) {
    throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)
  }

  return { member }
}

const spaceAdmin = async (spaceId: number, currentUserId: number): Promise<{ member: DbMember }> => {
  const member = await db._query.members.findFirst({
    where: and(
      eq(members.spaceId, spaceId),
      eq(members.userId, currentUserId),
      inArray(members.role, ["admin", "owner"]),
    ),
  })

  if (member === undefined) {
    throw new InlineError(InlineError.ApiError.SPACE_ADMIN_REQUIRED)
  }

  return { member }
}

/** Check if user is chat participant */
const chatParticipant = async (chatId: number, currentUserId: number) => {
  const participant = await db._query.chatParticipants.findFirst({
    where: and(eq(chatParticipants.chatId, chatId), eq(chatParticipants.userId, currentUserId)),
  })

  // Check if user is a participant in the chat
  if (participant === undefined) {
    throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)
  }

  return { participant }
}

/** Check if user has access to integrations by being a member of any space with integrations */
const hasIntegrationAccess = async (currentUserId: number): Promise<boolean> => {
  // Get all spaces the user is a member of
  const userSpaces = await db
    .select({ spaceId: members.spaceId })
    .from(members)
    .where(eq(members.userId, currentUserId))

  if (userSpaces.length === 0) {
    return false
  }

  const spaceIds = userSpaces.map((space) => space.spaceId)

  // Check if any of these spaces have integrations
  const spacesWithIntegrations = await db
    .select({ spaceId: integrations.spaceId })
    .from(integrations)
    .where(inArray(integrations.spaceId, spaceIds))

  // Also check for user-specific integrations (like Linear)
  const userIntegrations = await db.select().from(integrations).where(eq(integrations.userId, currentUserId))

  return spacesWithIntegrations.length > 0 || userIntegrations.length > 0
}

export const Authorize = {
  spaceOwner,
  spaceMember,
  chatParticipant,
  hasIntegrationAccess,
  spaceAdmin,
}
