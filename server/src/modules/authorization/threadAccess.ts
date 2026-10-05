import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import {
  chatParticipantGroups,
  chatParticipants,
  chats,
  members,
  spaces,
  userGroupMembers,
  userGroups,
  userNotDeleted,
  users,
  type DbChat,
} from "@in/server/db/schema"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { and, eq, isNull } from "drizzle-orm"
import type { Transaction } from "@in/server/db/types"

type ThreadAccessQuery = Pick<typeof db, "select"> | Pick<Transaction, "select">

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
    .innerJoin(chats, eq(chatParticipantGroups.chatId, chats.id))
    .innerJoin(userGroups, eq(chatParticipantGroups.groupId, userGroups.id))
    .innerJoin(userGroupMembers, eq(userGroups.id, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(users, eq(users.id, userGroupMembers.userId))
    .innerJoin(spaces, eq(spaces.id, userGroups.spaceId))
    .where(
      and(
        eq(chatParticipantGroups.chatId, chatId),
        eq(chats.type, "thread"),
        eq(chats.publicThread, false),
        eq(chats.spaceId, userGroups.spaceId),
        isNull(spaces.deleted),
        userNotDeleted(),
      ),
    )

  return uniqueIds(rows.map((row) => row.userId))
}

export async function getEffectiveAccessUserIds(chat: DbChat): Promise<number[]> {
  const access = await getEffectiveChatAccessUserIds(db, [chat.id])
  return Array.from(access.get(chat.id) ?? [])
}

export async function hasDirectParticipantGrant(
  chatId: number,
  userId: number,
  query: ThreadAccessQuery = db,
): Promise<boolean> {
  const participant = await query
    .select({ id: chatParticipants.id })
    .from(chatParticipants)
    .where(and(eq(chatParticipants.chatId, chatId), eq(chatParticipants.userId, userId)))
    .limit(1)

  const exists = participant.length > 0
  if (exists && query === db) {
    AccessGuardsCache.setChatParticipant(chatId, userId)
  }

  return exists
}

export async function hasGroupParticipantGrant(
  chatId: number,
  userId: number,
  query: ThreadAccessQuery = db,
): Promise<boolean> {
  const rows = await query
    .select({ id: chatParticipantGroups.id })
    .from(chatParticipantGroups)
    .innerJoin(chats, eq(chatParticipantGroups.chatId, chats.id))
    .innerJoin(userGroups, eq(chatParticipantGroups.groupId, userGroups.id))
    .innerJoin(userGroupMembers, eq(chatParticipantGroups.groupId, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(users, eq(users.id, userGroupMembers.userId))
    .innerJoin(spaces, eq(spaces.id, userGroups.spaceId))
    .where(
      and(
        eq(chatParticipantGroups.chatId, chatId),
        eq(userGroupMembers.userId, userId),
        eq(chats.type, "thread"),
        eq(chats.publicThread, false),
        eq(chats.spaceId, userGroups.spaceId),
        isNull(spaces.deleted),
        userNotDeleted(),
      ),
    )
    .limit(1)

  return rows.length > 0
}

export async function hasThreadAccessGrant(
  chatId: number,
  userId: number,
  query: ThreadAccessQuery = db,
): Promise<boolean> {
  if (await hasDirectParticipantGrant(chatId, userId, query)) {
    return true
  }

  return hasGroupParticipantGrant(chatId, userId, query)
}

function uniqueIds(ids: number[]): number[] {
  return Array.from(new Set(ids))
}
