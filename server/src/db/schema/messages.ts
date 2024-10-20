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
import { creationDate } from "@in/server/db/schema/common"
import { AnyPgColumn } from "drizzle-orm/pg-core"

export const messages = pgTable(
  "messages",
  {
    globalId: bigserial("global_id", { mode: "bigint" }).primaryKey(),

    // sequencial within one chat
    messageId: integer("message_id").notNull(),

    /** message raw text, optional */
    text: text(),

    /** required, chat it belongs to */
    chatId: integer("chat_id")
      .notNull()
      .references((): AnyPgColumn => chats.id, {
        onDelete: "cascade",
      }),

    /** required, chat it belongs to */
    fromId: integer("from_id")
      .notNull()
      .references(() => users.id),

    /** when it was edited. if null indicated it hasn't been edited */
    editDate: timestamp("edit_date", { mode: "date", precision: 3 }),

    date: creationDate,
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
