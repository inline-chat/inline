import type { ChatPermissions } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
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
import type { Transaction } from "@in/server/db/types"
import { and, eq, inArray } from "drizzle-orm"

type QueryExecutor = Pick<typeof db, "select"> | Pick<Transaction, "select">

export async function resolveChatPermissions(
  chat: DbChat,
  userId: number,
  query: QueryExecutor = db,
): Promise<ChatPermissions> {
  const permissions = await resolveChatPermissionsBatch([chat], userId, query)
  return permissions.get(chat.id) ?? { canUpdateInfo: false }
}

export async function resolveChatPermissionsBatch(
  inputChats: DbChat[],
  userId: number,
  query: QueryExecutor = db,
): Promise<Map<number, ChatPermissions>> {
  const permissionsByUserId = await resolveChatPermissionsForUsers(inputChats, [userId], query)
  return permissionsByUserId.get(userId) ?? new Map()
}

export async function resolveChatPermissionsForUsers(
  inputChats: DbChat[],
  userIds: number[],
  query: QueryExecutor = db,
): Promise<Map<number, Map<number, ChatPermissions>>> {
  const uniqueUserIds = Array.from(new Set(userIds))
  if (inputChats.length === 0 || uniqueUserIds.length === 0) {
    return new Map()
  }

  const chatsById = new Map(inputChats.map((chat) => [chat.id, chat]))
  let missingParentIds = parentIdsMissingFrom(inputChats, chatsById)

  while (missingParentIds.length > 0) {
    const parents = await query.select().from(chats).where(inArray(chats.id, missingParentIds))
    for (const parent of parents) {
      chatsById.set(parent.id, parent)
    }
    missingParentIds = parentIdsMissingFrom(parents, chatsById)
  }

  const chatIds = Array.from(chatsById.keys())
  const spaceIds = Array.from(
    new Set(
      Array.from(chatsById.values()).flatMap((chat) => (chat.spaceId == null ? [] : [chat.spaceId])),
    ),
  )

  const [directRows, groupRows, memberRows] = await Promise.all([
    query
      .select({ chatId: chatParticipants.chatId, userId: chatParticipants.userId })
      .from(chatParticipants)
      .where(
        and(inArray(chatParticipants.chatId, chatIds), inArray(chatParticipants.userId, uniqueUserIds)),
      ),
    query
      .select({ chatId: chatParticipantGroups.chatId, userId: userGroupMembers.userId })
      .from(chatParticipantGroups)
      .innerJoin(userGroups, eq(chatParticipantGroups.groupId, userGroups.id))
      .innerJoin(userGroupMembers, eq(chatParticipantGroups.groupId, userGroupMembers.groupId))
      .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
      .innerJoin(users, eq(users.id, userGroupMembers.userId))
      .where(
        and(
          inArray(chatParticipantGroups.chatId, chatIds),
          inArray(userGroupMembers.userId, uniqueUserIds),
          userNotDeleted(),
        ),
      ),
    spaceIds.length === 0
      ? Promise.resolve([])
      : query
          .select({
            spaceId: members.spaceId,
            userId: members.userId,
            role: members.role,
            canAccessPublicChats: members.canAccessPublicChats,
          })
          .from(members)
          .where(and(inArray(members.spaceId, spaceIds), inArray(members.userId, uniqueUserIds))),
  ])

  return new Map(
    uniqueUserIds.map((userId) => {
      const directGrantChatIds = new Set(
        directRows.filter((row) => row.userId === userId).map((row) => row.chatId),
      )
      const grantedChatIds = new Set([
        ...directGrantChatIds,
        ...groupRows.filter((row) => row.userId === userId).map((row) => row.chatId),
      ])
      const memberBySpaceId = new Map(
        memberRows.filter((member) => member.userId === userId).map((member) => [member.spaceId, member]),
      )

      const canAccessTopLevelChat = (chat: DbChat): boolean => {
        if (chat.type === "private") {
          return chat.minUserId === userId || chat.maxUserId === userId
        }

        if (chat.spaceId == null) {
          return grantedChatIds.has(chat.id)
        }

        const member = memberBySpaceId.get(chat.spaceId)
        if (!member) {
          return false
        }

        if (chat.publicThread) {
          return member.canAccessPublicChats !== false
        }

        return grantedChatIds.has(chat.id)
      }

      const canAccessChat = (chat: DbChat): boolean => {
        if (chat.type === "private") {
          return chat.minUserId === userId || chat.maxUserId === userId
        }

        if (grantedChatIds.has(chat.id)) {
          return true
        }

        const root = rootChat(chat, chatsById)
        return root ? canAccessTopLevelChat(root) : false
      }

      return [
        userId,
        new Map(
          inputChats.map((chat) => {
            let canUpdateInfo = false

            if (chat.type === "thread") {
              const member = chat.spaceId == null ? undefined : memberBySpaceId.get(chat.spaceId)
              const isReplyThreadAdmin =
                chat.parentMessageId != null && (member?.role === "owner" || member?.role === "admin")

              if (isReplyThreadAdmin) {
                canUpdateInfo = true
              } else if (canAccessChat(chat)) {
                canUpdateInfo =
                  chat.publicThread === true || chat.parentChatId != null || directGrantChatIds.has(chat.id)
              }
            }

            return [chat.id, { canUpdateInfo }]
          }),
        ),
      ]
    }),
  )
}

function parentIdsMissingFrom(rows: DbChat[], chatsById: Map<number, DbChat>): number[] {
  return Array.from(
    new Set(
      rows.flatMap((chat) =>
        chat.parentChatId != null && !chatsById.has(chat.parentChatId) ? [chat.parentChatId] : [],
      ),
    ),
  )
}

function rootChat(chat: DbChat, chatsById: Map<number, DbChat>): DbChat | undefined {
  let current = chat
  const seenIds = new Set<number>([chat.id])

  while (current.parentChatId != null) {
    if (!seenIds.add(current.parentChatId)) {
      return undefined
    }

    const parent = chatsById.get(current.parentChatId)
    if (!parent) {
      return undefined
    }
    current = parent
  }

  return current
}
