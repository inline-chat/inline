import {
  pgTable,
  varchar,
  boolean,
  timestamp,
  bigint,
  pgEnum,
  makePgArray,
  unique,
  check,
} from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { sql } from "drizzle-orm"
import { text } from "drizzle-orm/pg-core"
import { chats } from "./chats"
import { bigserial } from "drizzle-orm/pg-core"
import { integer } from "drizzle-orm/pg-core"
import { index } from "drizzle-orm/pg-core"

export const messages = pgTable(
  "messages",
  {
    id: bigserial({ mode: "bigint" }).primaryKey(),

    // sequencial within one chat
    messageId: integer("message_id").notNull(),

    /** message raw text, optional */
    text: text(),

    /** required, chat it belongs to */
    chatId: bigint("chat_id", { mode: "bigint" })
      .notNull()
      .references(() => chats.id, {
        onDelete: "cascade",
      }),

    /** required, chat it belongs to */
    from_id: bigint("from_id", { mode: "bigint" })
      .notNull()
      .references(() => users.id),

    /** when it was edited. if null indicated it hasn't been edited */
    editDate: timestamp("edit_date", { mode: "date", precision: 3 }),

    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({
    messageIdPerChatUnique: unique("msg_id_per_chat_unique").on(
      table.messageId,
      table.chatId,
    ),
    messageIdPerChatIndex: index("msg_id_per_chat_index").on(
      table.messageId,
      table.chatId,
    ),
  }),
)

export type DbMessage = typeof messages.$inferSelect
export type DbNewMessage = typeof messages.$inferInsert
