import type { Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { chats } from "@in/server/db/schema"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { resolveChatPermissionsForUsers } from "@in/server/modules/authorization/chatPermissions"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, eq, inArray, isNotNull, or } from "drizzle-orm"

type QueryExecutor = Pick<typeof db, "select"> | Pick<Transaction, "select">

export type PreparedChatPermissionUpdate = {
  userId: number
  update: Update
}

export async function prepareChatPermissionUpdates(
  input: {
    userIds: number[]
    chatIds: number[]
    includeDescendants?: boolean
  },
  options?: { tx?: Transaction },
): Promise<PreparedChatPermissionUpdate[]> {
  const userIds = uniqueIds(input.userIds)
  const chatIds = uniqueIds(input.chatIds)
  if (userIds.length === 0 || chatIds.length === 0) {
    return []
  }

  const query = options?.tx ?? db
  const chatRows = input.includeDescendants === false
    ? await query.select().from(chats).where(inArray(chats.id, chatIds))
    : await loadChatsAndDescendants(chatIds, query)
  const permissionsByUserId = await resolveChatPermissionsForUsers(chatRows, userIds, query)

  const entries = userIds.flatMap((userId) =>
    chatRows.map((chat) => {
      const permissions = permissionsByUserId.get(userId)?.get(chat.id) ?? { canUpdateInfo: false }
      return {
        userId,
        chatId: chat.id,
        permissions,
        serverUpdate: {
          oneofKind: "userChatPermissions" as const,
          userChatPermissions: {
            chatId: BigInt(chat.id),
            permissions,
          },
        },
      }
    }),
  )

  const persisted = await UserBucketUpdates.enqueueMany(
    entries.map((entry) => ({ userId: entry.userId, update: entry.serverUpdate })),
    options,
  )

  return entries.flatMap((entry, index) => {
    const saved = persisted[index]
    if (!saved) {
      return []
    }

    return [{
      userId: entry.userId,
      update: {
        seq: saved.seq,
        date: encodeDateStrict(saved.date),
        update: {
          oneofKind: "chatPermissions" as const,
          chatPermissions: {
            chatId: BigInt(entry.chatId),
            permissions: entry.permissions,
          },
        },
      },
    }]
  })
}

export async function prepareSpaceChatPermissionUpdates(
  input: { userIds: number[]; spaceId: number },
  options?: { tx?: Transaction },
): Promise<PreparedChatPermissionUpdate[]> {
  const query = options?.tx ?? db
  const rows = await query
    .select({ id: chats.id })
    .from(chats)
    .where(
      and(
        eq(chats.spaceId, input.spaceId),
        or(eq(chats.publicThread, true), isNotNull(chats.parentMessageId)),
      ),
    )
  return prepareChatPermissionUpdates(
    {
      userIds: input.userIds,
      chatIds: rows.map((row) => row.id),
      includeDescendants: false,
    },
    options,
  )
}

export function pushChatPermissionUpdates(updates: PreparedChatPermissionUpdate[]): void {
  const updatesByUserId = new Map<number, Update[]>()
  for (const prepared of updates) {
    const userUpdates = updatesByUserId.get(prepared.userId) ?? []
    userUpdates.push(prepared.update)
    updatesByUserId.set(prepared.userId, userUpdates)
  }

  for (const [userId, userUpdates] of updatesByUserId) {
    RealtimeUpdates.pushToUser(userId, userUpdates)
  }
}

async function loadChatsAndDescendants(chatIds: number[], query: QueryExecutor) {
  const rows = await query.select().from(chats).where(inArray(chats.id, chatIds))
  const seenIds = new Set(rows.map((chat) => chat.id))
  let parentIds = rows.map((chat) => chat.id)

  while (parentIds.length > 0) {
    const children = await query.select().from(chats).where(inArray(chats.parentChatId, parentIds))
    parentIds = []
    for (const child of children) {
      if (seenIds.add(child.id)) {
        rows.push(child)
        parentIds.push(child.id)
      }
    }
  }

  return rows
}

function uniqueIds(ids: number[]): number[] {
  return Array.from(new Set(ids.filter((id) => Number.isSafeInteger(id) && id > 0)))
}
