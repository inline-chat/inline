import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import {
  chatParticipantGroups,
  chatParticipants,
  chats,
  members,
  userGroupMembers,
  userGroups,
  userNotDeleted,
  users,
  type DbChat,
} from "@in/server/db/schema"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { and, eq } from "drizzle-orm"

export async function getDirectParticipantUserIds(chatId: number): Promise<number[]> {
  const participants = await db
    .select({ userId: chatParticipants.userId })
    .from(chatParticipants)
    .where(eq(chatParticipants.chatId, chatId))

  return UsersModel.getActiveUserIds(participants.map((participant) => participant.userId))
}

export async function getGroupParticipantUserIds(chatId: number): Promise<number[]> {
  const rows = await db
    .select({ userId: userGroupMembers.userId })
    .from(chatParticipantGroups)
    .innerJoin(userGroups, eq(chatParticipantGroups.groupId, userGroups.id))
    .innerJoin(userGroupMembers, eq(userGroups.id, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(users, eq(users.id, userGroupMembers.userId))
    .where(and(eq(chatParticipantGroups.chatId, chatId), userNotDeleted()))

  return uniqueIds(rows.map((row) => row.userId))
}

export async function getTopLevelAccessUserIds(chat: DbChat): Promise<number[]> {
  if (chat.type === "private") {
    if (chat.minUserId == null || chat.maxUserId == null) {
      return []
    }

    if (chat.minUserId === chat.maxUserId) {
      return UsersModel.getActiveUserIds([chat.minUserId])
    }

    return UsersModel.getActiveUserIds([chat.minUserId, chat.maxUserId])
  }

  if (chat.spaceId == null) {
    return getGrantedUserIds(chat.id)
  }

  if (chat.publicThread) {
    const publicMembers = await db
      .select({ userId: members.userId })
      .from(members)
      .where(and(eq(members.spaceId, chat.spaceId), eq(members.canAccessPublicChats, true)))

    return UsersModel.getActiveUserIds(publicMembers.map((member) => member.userId))
  }

  return getGrantedUserIds(chat.id)
}

export async function getInheritedAccessUserIds(chat: DbChat): Promise<number[]> {
  if (chat.parentChatId == null) {
    return getTopLevelAccessUserIds(chat)
  }

  const parentChat = await getChatById(chat.parentChatId)
  if (!parentChat) {
    return []
  }

  return getInheritedAccessUserIds(parentChat)
}

export async function getEffectiveAccessUserIds(chat: DbChat): Promise<number[]> {
  const [grantedUserIds, inheritedUserIds] = await Promise.all([
    getGrantedUserIds(chat.id),
    getInheritedAccessUserIds(chat),
  ])

  return uniqueIds([...grantedUserIds, ...inheritedUserIds])
}

export async function hasDirectParticipantGrant(chatId: number, userId: number): Promise<boolean> {
  const cachedParticipant = AccessGuardsCache.getChatParticipant(chatId, userId)
  if (cachedParticipant !== undefined) {
    return cachedParticipant
  }

  const participant = await db
    .select({ id: chatParticipants.id })
    .from(chatParticipants)
    .where(and(eq(chatParticipants.chatId, chatId), eq(chatParticipants.userId, userId)))
    .limit(1)

  const exists = participant.length > 0
  if (exists) {
    AccessGuardsCache.setChatParticipant(chatId, userId)
  }

  return exists
}

export async function hasGroupParticipantGrant(chatId: number, userId: number): Promise<boolean> {
  const rows = await db
    .select({ id: chatParticipantGroups.id })
    .from(chatParticipantGroups)
    .innerJoin(userGroups, eq(chatParticipantGroups.groupId, userGroups.id))
    .innerJoin(userGroupMembers, eq(chatParticipantGroups.groupId, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(users, eq(users.id, userGroupMembers.userId))
    .where(
      and(
        eq(chatParticipantGroups.chatId, chatId),
        eq(userGroupMembers.userId, userId),
        userNotDeleted(),
      ),
    )
    .limit(1)

  return rows.length > 0
}

export async function hasThreadAccessGrant(chatId: number, userId: number): Promise<boolean> {
  if (await hasDirectParticipantGrant(chatId, userId)) {
    return true
  }

  return hasGroupParticipantGrant(chatId, userId)
}

async function getGrantedUserIds(chatId: number): Promise<number[]> {
  const [directUserIds, groupUserIds] = await Promise.all([
    getDirectParticipantUserIds(chatId),
    getGroupParticipantUserIds(chatId),
  ])

  return uniqueIds([...directUserIds, ...groupUserIds])
}

async function getChatById(chatId: number): Promise<DbChat | undefined> {
  return db
    .select()
    .from(chats)
    .where(eq(chats.id, chatId))
    .limit(1)
    .then((rows) => rows[0])
}

function uniqueIds(ids: number[]): number[] {
  return Array.from(new Set(ids))
}
