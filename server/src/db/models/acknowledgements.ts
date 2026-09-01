import type { ChatAcknowledgement } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { acknowledgements } from "@in/server/db/schema"
import { UsersModel } from "@in/server/db/models/users"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { inArray, asc } from "drizzle-orm"
import type { Transaction } from "@in/server/db/types"

/** Batched snapshot projection of one durable cursor state for each actor and chat. */
export async function getChatAcknowledgements(
  chatIds: number[],
  options?: { tx?: Transaction },
): Promise<Map<number, ChatAcknowledgement[]>> {
  const result = new Map<number, ChatAcknowledgement[]>()
  if (chatIds.length === 0) return result
  const query = options?.tx ?? db
  const rows = await query.select({
    chatId: acknowledgements.chatId,
    userId: acknowledgements.userId,
    maxId: acknowledgements.maxId,
    revision: acknowledgements.revision,
    cleared: acknowledgements.cleared,
  }).from(acknowledgements)
    .where(inArray(acknowledgements.chatId, chatIds))
    .orderBy(asc(acknowledgements.chatId), asc(acknowledgements.userId))
  if (rows.length === 0) return result

  // Tombstones need no avatar sidecar; active markers hydrate before first render.
  const activeUserIds = [...new Set(rows.filter(row => !row.cleared).map(row => row.userId))]
  const actors = activeUserIds.length > 0 ? await UsersModel.getUsersWithPhotos(activeUserIds, options) : []
  const users = new Map(actors.map(row => [row.user.id, encodeUser({ user: row.user, photoFile: row.photoFile, min: true })]))
  for (const row of rows) {
    const cursors = result.get(row.chatId) ?? []
    cursors.push({
      chatId: BigInt(row.chatId),
      userId: BigInt(row.userId),
      maxId: BigInt(row.maxId),
      revision: BigInt(row.revision),
      cleared: row.cleared,
      user: row.cleared ? undefined : users.get(row.userId),
    })
    result.set(row.chatId, cursors)
  }
  return result
}
