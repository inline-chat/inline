import { pgTable, boolean, unique, integer, text, bytea, index, timestamp } from "drizzle-orm/pg-core"
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

    /** legacy visibility column kept in DB while chat_list_hidden rolls out */
    legacySidebarVisible: boolean("sidebar_visible").default(true).notNull(),

    /** whether this dialog should be hidden from chat list/home lists; null means false */
    chatListHidden: boolean("chat_list_hidden"),

    /** sidebar inbox state; null means use the chat-type default */
    open: boolean("open"),

    /** when the dialog transitioned into the sidebar inbox */
    openedDate: timestamp("opened_date", { mode: "date", precision: 3 }),

    /** fractional order for normal sidebar inbox rows */
    order: text("order"),

    /** fractional order for pinned sidebar rows */
    pinnedOrder: text("pinned_order"),

    /** manually marked as unread */
    unreadMark: boolean("unread_mark").default(false),

    /** Per-chat notification settings override as protobuf bytes (null => inherit global settings) */
    notificationSettings: bytea("notification_settings"),

    /** Reply-thread automatic surfacing policy; null means relevance-only default */
    followMode: text("follow_mode", { enum: ["following"] }),
  },
  (table) => ({
    chatIdUserIdUnique: unique("chat_id_user_id_unique").on(table.chatId, table.userId),
    userIdChatIdIndex: index("dialogs_user_id_chat_id_idx").on(table.userId, table.chatId),
    userIdPeerUserIdIndex: index("dialogs_user_id_peer_user_id_idx").on(table.userId, table.peerUserId),
    userIdOrderIndex: index("dialogs_user_id_order_idx").on(table.userId, table.order),
    userIdPinnedOrderIndex: index("dialogs_user_id_pinned_order_idx").on(table.userId, table.pinnedOrder),
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
