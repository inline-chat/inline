import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { members, spaces, type DbMember, chatParticipants } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"

/** Check if user is creator of space */
const spaceCreator = async (spaceId: number, currentUserId: number) => {
  const space = await db._query.spaces.findFirst({
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

export const Authorize = {
  spaceCreator,
  spaceMember,
  chatParticipant,
}
