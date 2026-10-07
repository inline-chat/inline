import { eq, sql, and, gt, ne, inArray, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { dialogs, messages } from "@in/server/db/schema"

export class DialogsModel {
  static async getUserIdsWeHavePrivateDialogsWith({ userId }: { userId: number }): Promise<number[]> {
    const dialogs_ = await db.select({ userId: dialogs.peerUserId }).from(dialogs).where(eq(dialogs.userId, userId))
    return dialogs_.map(({ userId }) => userId).filter((userId): userId is number => userId != null)
  }

  // Read counts and manual marks together, including dialogs with no unread messages.
  static async getBatchUnreadCounts({
    userId,
    chatIds,
    tx,
  }: {
    userId: number
    chatIds: number[]
    tx?: Transaction
  }) {
    const query = tx ?? db
    const unreadCounts = await query
      .select({
        chatId: dialogs.chatId,
        unreadCount: sql<number>`count(${messages.chatId})::int`,
        unreadMark: dialogs.unreadMark,
      })
      .from(dialogs)
      .leftJoin(
        messages,
        and(
          eq(messages.chatId, dialogs.chatId),
          gt(messages.messageId, sql`COALESCE(${dialogs.readInboxMaxId}, 0)`),
          ne(messages.fromId, userId),
          eq(messages.countsAsUnread, true),
          isNull(messages.systemMessageEncrypted),
        ),
      )
      .where(and(eq(dialogs.userId, userId), inArray(dialogs.chatId, chatIds)))
      .groupBy(dialogs.chatId, dialogs.unreadMark)

    const unreadByChatId = new Map(unreadCounts.map((row) => [row.chatId, row]))

    // Ensure we return 0 for chats with no unread messages
    return chatIds.map((chatId) => ({
      chatId,
      unreadCount: unreadByChatId.get(chatId)?.unreadCount ?? 0,
      unreadMark: unreadByChatId.get(chatId)?.unreadMark === true,
    }))
  }

  // AI did this, check more
  static async getUnreadCount(chatId: number, userId: number, tx?: Transaction) {
    const query = tx ?? db
    const [result] = await query
      .select({
        count: sql<number>`count(*)::int`,
      })
      .from(messages)
      .innerJoin(dialogs, and(eq(dialogs.chatId, messages.chatId), eq(dialogs.userId, userId)))
      .where(
        and(
          eq(messages.chatId, chatId),
          gt(messages.messageId, sql`COALESCE(${dialogs.readInboxMaxId}, 0)`),
          ne(messages.fromId, userId),
          eq(messages.countsAsUnread, true),
          isNull(messages.systemMessageEncrypted),
        ),
      )
    return result?.count ?? 0
  }
}
