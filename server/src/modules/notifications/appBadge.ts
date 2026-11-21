import { sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { ACTIVITY_KIND_MENTION, ACTIVITY_KIND_REPLY } from "@in/server/db/schema"

/**
 * The iOS app icon badge: how many chats the chat list shows in blue. A prominent unread chat
 * (DM, private chat or followed thread, not muted), or any chat with an unseen mention or reply.
 * Mirrors `Dialog.appBadgeSQL` on Apple clients, which keep the badge while the app is active.
 *
 * A muted dialog's settings blob starts with field 1 = MODE_NONE (`08 03`), as the clients read it.
 */
export async function getAppBadgeCount(userId: number): Promise<number> {
  const [row] = await db.execute<{ count: number | string }>(sql`
    SELECT count(*)::int AS count
    FROM dialogs d
    JOIN chats c ON c.id = d.chat_id
    WHERE d.user_id = ${userId}
      AND d.archived IS NOT TRUE
      -- Clients read a missing flag from the legacy sidebar column.
      AND COALESCE(d.chat_list_hidden, NOT d.sidebar_visible) IS NOT TRUE
      AND (
        (
          (d.peer_user_id IS NOT NULL OR d.follow_mode = 'following' OR c.type = 'private')
          AND COALESCE(substring(d.notification_settings FROM 1 FOR 2) <> decode('0803', 'hex'), true)
          AND (
            d.unread_mark IS TRUE
            OR EXISTS (
              SELECT 1 FROM messages m
              WHERE m.chat_id = d.chat_id
                AND m.message_id > COALESCE(d.read_inbox_max_id, 0)
                AND m.from_id <> ${userId}
                AND m.counts_as_unread
                AND m.system_message_encrypted IS NULL
            )
          )
        )
        OR EXISTS (
          SELECT 1 FROM activity_items a
          WHERE a.user_id = ${userId}
            AND a.chat_id = d.chat_id
            AND a.kind IN (${ACTIVITY_KIND_MENTION}, ${ACTIVITY_KIND_REPLY})
            AND a.read_at IS NULL
        )
      )
  `)
  return Number(row?.count ?? 0)
}
