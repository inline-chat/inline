import { DialogsModel } from "@in/server/db/models/dialogs"
import { spaces, type DbChat, type DbDialog } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { getActivityCountsForChats } from "@in/server/modules/activityItems"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { Dialog, Space } from "@inline-chat/protocol/core"
import { and, inArray, isNull } from "drizzle-orm"

/** The viewer's dialogs with their unread message and activity counts, in input order. */
export async function encodeViewerDialogs(
  tx: Transaction,
  viewerUserId: number,
  dialogRows: DbDialog[],
): Promise<Dialog[]> {
  if (dialogRows.length === 0) return []
  const chatIds = dialogRows.map((dialog) => dialog.chatId)
  const unreadCounts = new Map(
    (await DialogsModel.getBatchUnreadCounts({ userId: viewerUserId, chatIds, tx }))
      .map((row) => [row.chatId, row.unreadCount]),
  )
  const activityCounts = await getActivityCountsForChats({ userId: viewerUserId, chatIds, tx })
  return dialogRows.map((dialog) =>
    Encoders.dialog(dialog, {
      unreadCount: unreadCounts.get(dialog.chatId) ?? 0,
      unreadActivity: activityCounts.get(dialog.chatId),
    }),
  )
}

/** Non-deleted spaces the chats belong to. */
export async function encodeChatSpaces(
  tx: Transaction,
  viewerUserId: number,
  chatRows: Pick<DbChat, "spaceId">[],
): Promise<Space[]> {
  const spaceIds = [...new Set(chatRows.flatMap((chat) => (chat.spaceId == null ? [] : [chat.spaceId])))]
  if (spaceIds.length === 0) return []
  const rows = await tx.select().from(spaces).where(and(inArray(spaces.id, spaceIds), isNull(spaces.deleted)))
  return rows.map((space) => Encoders.space(space, { encodingForUserId: viewerUserId }))
}
