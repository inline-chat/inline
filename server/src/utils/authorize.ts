import { db } from "@in/server/db"
import { and, eq, inArray } from "drizzle-orm"
import { members, spaces, type DbMember, chatParticipants, integrations, chats } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("authorize")

type AuthLogDetails = Record<string, string | number | boolean | null | undefined>

const logDenied = async (
  check: string,
  details: AuthLogDetails,
  loadDetails?: () => Promise<AuthLogDetails>,
) => {
  try {
    log.warn("Authorization denied", {
      check,
      ...details,
      ...(loadDetails ? await loadDetails() : {}),
    })
  } catch {
    log.warn("Authorization denied", { check, ...details, diagnosticsFailed: true })
  }
}

const getSpaceDetails = async (spaceId: number, currentUserId: number): Promise<AuthLogDetails> => {
  const [space] = await db
    .select({
      creatorId: spaces.creatorId,
      isPublic: spaces.isPublic,
      deleted: spaces.deleted,
    })
    .from(spaces)
    .where(eq(spaces.id, spaceId))
    .limit(1)

  return {
    spaceExists: !!space,
    spaceDeleted: space ? space.deleted !== null : undefined,
    spaceIsPublic: space?.isPublic,
    currentUserIsCreator: space ? space.creatorId === currentUserId : undefined,
  }
}

const getMemberDetails = async (spaceId: number, currentUserId: number): Promise<AuthLogDetails> => {
  const [member] = await db
    .select({
      role: members.role,
      canAccessPublicChats: members.canAccessPublicChats,
    })
    .from(members)
    .where(and(eq(members.spaceId, spaceId), eq(members.userId, currentUserId)))
    .limit(1)

  return {
    memberExists: !!member,
    memberRole: member?.role,
    canAccessPublicChats: member?.canAccessPublicChats,
  }
}

const getChatDetails = async (chatId: number, currentUserId: number): Promise<AuthLogDetails> => {
  const [chat] = await db
    .select({
      type: chats.type,
      spaceId: chats.spaceId,
      publicThread: chats.publicThread,
      parentChatId: chats.parentChatId,
      parentMessageId: chats.parentMessageId,
      minUserId: chats.minUserId,
      maxUserId: chats.maxUserId,
    })
    .from(chats)
    .where(eq(chats.id, chatId))
    .limit(1)

  const member = chat?.spaceId ? await getMemberDetails(chat.spaceId, currentUserId) : {}

  return {
    chatExists: !!chat,
    chatType: chat?.type,
    chatSpaceId: chat?.spaceId ?? null,
    chatPublicThread: chat?.publicThread ?? null,
    chatParentChatId: chat?.parentChatId ?? null,
    chatParentMessageId: chat?.parentMessageId ?? null,
    isPrivatePairMember:
      chat?.type === "private" ? chat.minUserId === currentUserId || chat.maxUserId === currentUserId : undefined,
    ...member,
  }
}

/** Check if user is creator of space */
const spaceCreator = async (spaceId: number, currentUserId: number) => {
  const space = await db._query.spaces.findFirst({
    where: and(eq(spaces.id, spaceId), eq(spaces.creatorId, currentUserId)),
  })

  // Check if space that we are trying to use as creator exists
  if (space === undefined) {
    await logDenied("spaceCreator", { spaceId, currentUserId }, () => getSpaceDetails(spaceId, currentUserId))
    throw new InlineError(InlineError.ApiError.SPACE_CREATOR_REQUIRED)
  }

  // Check if space is deleted, which means we can't use it
  if (space.deleted !== null) {
    await logDenied("spaceCreator", { spaceId, currentUserId, spaceDeleted: true }, () =>
      getSpaceDetails(spaceId, currentUserId),
    )
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
    await logDenied("spaceMember", { spaceId, currentUserId, memberExists: false }, () =>
      getSpaceDetails(spaceId, currentUserId),
    )
    throw new InlineError(InlineError.ApiError.USER_NOT_PARTICIPANT)
  }

  return { member }
}

const spaceAdmin = async (spaceId: number, currentUserId: number): Promise<{ member: DbMember }> => {
  const member = await db.query.members.findFirst({
    where: {
      spaceId,
      userId: currentUserId,
      OR: [{ role: "admin" }, { role: "owner" }],
    },
  })

  if (member === undefined) {
    await logDenied("spaceAdmin", { spaceId, currentUserId }, async () => ({
      ...(await getSpaceDetails(spaceId, currentUserId)),
      ...(await getMemberDetails(spaceId, currentUserId)),
    }))
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
    await logDenied("chatParticipant", { chatId, currentUserId, participantExists: false }, () =>
      getChatDetails(chatId, currentUserId),
    )
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
  spaceCreator,
  spaceMember,
  chatParticipant,
  hasIntegrationAccess,
  spaceAdmin,
}
