import { db } from "@in/server/db"
import { sql } from "drizzle-orm"
import {
  decodeDialogNotificationSettings,
  isValidDialogNotificationMode,
} from "./dialogNotificationSettings"

/** Resolve each recipient's nearest explicit setting in one indexed ancestor lookup. */
export async function getInheritedDialogNotificationSettings(chatId: number, userIds: number[]) {
  const settings = new Map<number, NonNullable<ReturnType<typeof decodeDialogNotificationSettings>>>()
  if (userIds.length === 0) return settings

  const rows = await db.execute<{ userId: number; notificationSettings: Buffer }>(sql`
    with recursive ancestry as (
      select id, parent_chat_id, array[id] as path
      from chats where id = ${chatId}
      union all
      select parent.id, parent.parent_chat_id, ancestry.path || parent.id
      from chats parent join ancestry on parent.id = ancestry.parent_chat_id
      where not parent.id = any(ancestry.path)
    )
    select d.user_id as "userId", d.notification_settings as "notificationSettings"
    from ancestry join dialogs d on d.chat_id = ancestry.id
    where d.user_id in (${sql.join(userIds.map((id) => sql`${id}`), sql`, `)})
      and d.notification_settings is not null
    order by cardinality(ancestry.path)
  `)

  for (const row of rows) {
    if (settings.has(row.userId)) continue
    const decoded = decodeDialogNotificationSettings(row.notificationSettings)
    if (decoded && isValidDialogNotificationMode(decoded.mode)) settings.set(row.userId, decoded)
  }
  return settings
}
