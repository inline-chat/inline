import { pgTable, boolean, unique, integer, text } from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { relations } from "drizzle-orm/_relations"
import { chats } from "./chats"
import { creationDate } from "@in/server/db/schema/common"
import { serial } from "drizzle-orm/pg-core"

export const dialogs = pgTable(
  "dialogs",
  {
    /** internal id */
    id: serial().primaryKey(),

    /** for which user in the chat */
    userId: integer("user_id")
      .references(() => users.id)
      .notNull(),

    /** which chat */
    chatId: integer("chat_id")
      .references(() => chats.id, {
        onDelete: "cascade",
      })
      .notNull(),

    /** optional, if for a private chat */
    peerUserId: integer("peer_user_id").references(() => users.id),

    /** optional, if for a thread that is part of a space */
    spaceId: integer("space_id").references(() => spaces.id),

    date: creationDate,

    /** read inbox max id (used for unread count/position) */
    readInboxMaxId: integer("read_inbox_max_id"),

    // this seems wrong LOL
    /** read outbox max id (used for second checkmark) */
    readOutboxMaxId: integer("read_outbox_max_id"),

    /** Is it pinned? */
    pinned: boolean("pinned"),

    /** draft message */
    draft: text("draft"),

    /** archived */
    archived: boolean("archived").default(false),

    /** manually marked as unread */
    unreadMark: boolean("unread_mark").default(false),
  },
  (table) => ({
    chatIdUserIdUnique: unique("chat_id_user_id_unique").on(table.chatId, table.userId),
  }),
)

export const dialogsRelations = relations(dialogs, ({ one }) => ({
  chat: one(chats, {
    fields: [dialogs.chatId],
    references: [chats.id],
  }),

  space: one(spaces, {
    fields: [dialogs.spaceId],
    references: [spaces.id],
  }),

  user: one(users, {
    fields: [dialogs.userId],
    references: [users.id],
  }),
}))

export type DbDialog = typeof dialogs.$inferSelect
export type DbNewDialog = typeof dialogs.$inferInsert
