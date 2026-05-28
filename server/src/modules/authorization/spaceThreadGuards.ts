import { db } from "@in/server/db"
import { members, type DbChat, type DbMember } from "@in/server/db/schema"
import { getSpacePrivacyContext, type SpacePrivacyContext } from "@in/server/modules/privacy/spacePrivacy"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq, inArray } from "drizzle-orm"

export async function ensureCanCreateSpaceThread(input: {
  spaceId: number
  userId: number
  isPublic: boolean
  participantUserIds?: number[]
}): Promise<SpacePrivacyContext> {
  const privacy = await getSpacePrivacyContext(input.spaceId, input.userId)
  if (input.isPublic) {
    ensurePublicChatAccess(privacy.member)
    return privacy
  }

  await ensureSpaceMembers(input.spaceId, input.participantUserIds ?? [])
  return privacy
}

export async function ensureCanManageChatParticipants(chat: DbChat, userId: number): Promise<void> {
  if (chat.spaceId == null) {
    if (chat.createdBy !== userId) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  const privacy = await getSpacePrivacyContext(chat.spaceId, userId)
  if (chat.createdBy === userId || privacy.canManageMembers) {
    return
  }

  throw RealtimeRpcError.SpaceAdminRequired()
}

export async function ensureUserCanParticipateInChat(chat: DbChat, userId: number): Promise<void> {
  if (chat.spaceId == null) {
    return
  }

  const [member] = await db
    .select()
    .from(members)
    .where(and(eq(members.spaceId, chat.spaceId), eq(members.userId, userId)))
    .limit(1)

  if (!member) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  if (chat.publicThread) {
    ensurePublicChatAccess(member)
  }
}

export async function ensureSpaceMembers(spaceId: number, userIds: number[]): Promise<void> {
  const uniqueUserIds = [...new Set(userIds)]
  if (uniqueUserIds.length === 0) {
    return
  }

  const validMembers = await db
    .select({ userId: members.userId })
    .from(members)
    .where(and(eq(members.spaceId, spaceId), inArray(members.userId, uniqueUserIds)))

  if (validMembers.length !== uniqueUserIds.length) {
    throw RealtimeRpcError.UserIdInvalid()
  }
}

function ensurePublicChatAccess(member: DbMember): void {
  if (member.canAccessPublicChats === false) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}
