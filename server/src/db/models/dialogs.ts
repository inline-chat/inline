import { eq, sql, and, gt, ne, inArray, desc } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogs, messages } from "@in/server/db/schema"

export class DialogsModel {
  static async getUserIdsWeHavePrivateDialogsWith({ userId }: { userId: number }): Promise<number[]> {
    const dialogs_ = await db.select({ userId: dialogs.peerUserId }).from(dialogs).where(eq(dialogs.userId, userId))
    return dialogs_.map(({ userId }) => userId).filter((userId): userId is number => userId != null)
  }

  // TODO: AI - generated, Optimize
  static async getBatchUnreadCounts({ userId, chatIds }: { userId: number; chatIds: number[] }) {
    const unreadCounts = await db
      .select({
        chatId: messages.chatId,
        unreadCount: sql<number>`count(*)::int`,
      })
      .from(messages)
      .innerJoin(dialogs, and(eq(dialogs.chatId, messages.chatId), eq(dialogs.userId, userId)))
      .where(
        and(
          inArray(messages.chatId, chatIds),
          gt(messages.messageId, sql`COALESCE(${dialogs.readInboxMaxId}, 0)`),
          ne(messages.fromId, userId),
        ),
      )
      .groupBy(messages.chatId)

    // Convert to a map for easier lookup
    const countMap = new Map(unreadCounts.map(({ chatId, unreadCount }) => [chatId, unreadCount]))

    // Ensure we return 0 for chats with no unread messages
    return chatIds.map((chatId) => ({
      chatId,
      unreadCount: countMap.get(chatId) ?? 0,
    }))
  }

  // AI did this, check more
  static async getUnreadCount(chatId: number, userId: number) {
    const [result] = await db
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
        ),
      )
    return result?.count ?? 0
  }
}
