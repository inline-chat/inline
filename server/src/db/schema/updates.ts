import { chats } from "@in/server/db/schema/chats"
import { creationDate } from "@in/server/db/schema/common"
import { spaces } from "@in/server/db/schema/spaces"
import { users } from "@in/server/db/schema/users"
import { pgTable, serial, integer, bigint, bytea, varchar, pgEnum, index, unique } from "drizzle-orm/pg-core"

export const updates = pgTable(
  "updates",
  {
    id: integer("id").generatedAlwaysAsIdentity().primaryKey(),
    date: creationDate,

    // box of updates
    pts: integer("pts"),

    // type of message box it belongs to
    box: varchar("box", {
      enum: [
        // chat
        "c",
        // user
        "u",
        // space
        "s",
      ],
    }).notNull(),

    // if related to a chat
    chatId: integer("chat_id").references(() => chats.id),

    // if related to space id
    spaceId: integer("space_id").references(() => spaces.id),

    // if related to a user
    userId: integer("user_id").references(() => users.id),

    // Encrypted update text
    update: bytea("update").notNull(),
    updateIv: bytea("update_iv").notNull(),
    updateTag: bytea("update_tag").notNull(),
  },
  (t) => [
    index("updates_chat_idx").on(t.box, t.chatId, t.pts),
    index("updates_user_idx").on(t.box, t.userId, t.pts),
    index("updates_space_idx").on(t.box, t.spaceId, t.pts),
    index("updates_date_idx").on(t.date),
    unique("updates_unique").on(t.box, t.chatId, t.userId, t.spaceId, t.pts).nullsNotDistinct(),
  ],
)

export type DbUpdate = typeof updates.$inferSelect
export type DbNewUpdate = typeof updates.$inferInsert
