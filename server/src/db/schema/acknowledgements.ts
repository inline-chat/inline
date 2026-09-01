import { boolean, index, integer, pgTable, primaryKey } from "drizzle-orm/pg-core"
import { chats } from "./chats"
import { users } from "./users"

// No message FK: deleting a target must not rewind the actor's explicit cursor.
export const acknowledgements = pgTable("chat_acknowledgements", {
  chatId: integer("chat_id").notNull().references(() => chats.id, { onDelete: "cascade" }),
  userId: integer("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  maxId: integer("max_id").notNull(),
  revision: integer("revision").notNull().default(0),
  cleared: boolean("cleared").notNull().default(false),
}, table => [
  primaryKey({ columns: [table.chatId, table.userId] }),
  index("chat_acknowledgements_user_id_idx").on(table.userId),
])
