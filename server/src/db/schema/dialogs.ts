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
import { chats } from "./chats"
import { bigserial } from "drizzle-orm/pg-core"

export const dialogs = pgTable(
  "dialogs",
  {
    /** internal id */
    id: bigserial({ mode: "bigint" }),

    /** which chat */
    chatId: bigint("chat_id", { mode: "bigint" }).references(() => chats.id, {
      onDelete: "cascade",
    }),

    /** which user in the chat */
    userId: bigint("user_id", { mode: "bigint" }).references(() => users.id),

    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({
    chatIdUserIdUnique: unique("chat_id_user_id_unique").on(
      table.chatId,
      table.userId,
    ),
  }),
)

export type DbDialog = typeof dialogs.$inferSelect
export type DbNewDialog = typeof dialogs.$inferInsert
