import { sql } from "drizzle-orm"
import { foreignKey, index, integer, pgTable, primaryKey, smallint, timestamp } from "drizzle-orm/pg-core"
import { users } from "./users"
import { messages } from "./messages"

// Mention, reply and reaction activity addressed to one user. A row is unread until read_at is set.
// Read rows are kept so a cross-chat activity feed can be built from the same table.
// Stored values are append-only. The wire folds replies into mentions; the table keeps them apart.
export const ACTIVITY_KIND_MENTION = 1
export const ACTIVITY_KIND_REPLY = 2
export const ACTIVITY_KIND_REACTION = 3

export type DbActivityKind = typeof ACTIVITY_KIND_MENTION | typeof ACTIVITY_KIND_REPLY | typeof ACTIVITY_KIND_REACTION

export const activityItems = pgTable(
  "activity_items",
  {
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    chatId: integer("chat_id").notNull(),
    messageId: integer("message_id").notNull(),
    kind: smallint("kind").$type<DbActivityKind>().notNull(),
    // Sender for mentions and replies, latest reactor for reactions.
    actorUserId: integer("actor_user_id"),
    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow().notNull(),
    readAt: timestamp("read_at", { mode: "date", precision: 3 }),
  },
  (table) => [
    primaryKey({ columns: [table.userId, table.chatId, table.kind, table.messageId] }),
    // Message deletion paths emit removal updates before deleting; the cascade is a backstop.
    foreignKey({
      name: "activity_items_message_fk",
      columns: [table.chatId, table.messageId],
      foreignColumns: [messages.chatId, messages.messageId],
    }).onDelete("cascade"),
    // Badge counts and in-chat navigation only touch unread rows.
    index("activity_items_unread_idx")
      .on(table.userId, table.chatId, table.kind, table.messageId)
      .where(sql`${table.readAt} IS NULL`),
    index("activity_items_message_idx").on(table.chatId, table.messageId),
    // Cross-chat activity feed.
    index("activity_items_user_date_idx").on(table.userId, table.date.desc()),
  ],
)

export type DbActivityItem = typeof activityItems.$inferSelect
export type DbNewActivityItem = typeof activityItems.$inferInsert
