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
  integer,
} from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { sql } from "drizzle-orm"
import { chats } from "./chats"
import { bigserial } from "drizzle-orm/pg-core"
import { creationDate } from "@in/server/db/schema/common"
import { serial } from "drizzle-orm/pg-core"

export const dialogs = pgTable(
  "dialogs",
  {
    /** internal id */
    id: serial().primaryKey(),

    /** which chat */
    chatId: integer("chat_id").references(() => chats.id, {
      onDelete: "cascade",
    }),

    /** which user in the chat */
    userId: bigint("user_id", { mode: "bigint" }).references(() => users.id),

    date: creationDate,
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
