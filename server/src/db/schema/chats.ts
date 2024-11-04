import { pgTable, varchar, boolean, timestamp, bigint, pgEnum, makePgArray, unique, check } from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { sql } from "drizzle-orm"
import { bigserial } from "drizzle-orm/pg-core"
import { creationDate } from "@in/server/db/schema/common"
import { integer } from "drizzle-orm/pg-core"
import { messages } from "@in/server/db/schema/messages"
import { AnyPgColumn } from "drizzle-orm/pg-core"
import { foreignKey } from "drizzle-orm/pg-core"
import { text } from "drizzle-orm/pg-core"

export const chatTypeEnum = pgEnum("chat_types", ["private", "thread"])

export const chats = pgTable(
  "chats",
  {
    id: integer().primaryKey().generatedAlwaysAsIdentity(),
    type: chatTypeEnum().notNull(),
    title: varchar({ length: 150 }),
    description: text(),
    emoji: varchar({ length: 20 }),

    /** Most recent message id */
    maxMsgId: integer("max_msg_id"),

    /** optional, if part of a space */
    spaceId: integer("space_id").references(() => spaces.id),

    /** optional, required for space chats, defaults to false */
    spacePublic: boolean("space_public"),

    /** optional, required for space chats, thread number */
    threadNumber: integer("thread_number"),

    /** optional, required for private chats, least user id */
    minUserId: integer("min_user_id").references(() => users.id),

    /** optional, required for private chats, greatest user id */
    maxUserId: integer("max_user_id").references(() => users.id),

    date: creationDate,

    /** optional, required for private chats, peer user id */
    peerUserId: integer("peer_user_id").references(() => users.id),
  },
  (table) => ({
    /** Ensure correctness */
    userIdsCheckConstraint: check("user_ids_check", sql`${table.minUserId} < ${table.maxUserId}`),
    /** Ensure single private chat exists for each user pair */
    userIdsUniqueContraint: unique("user_ids_unique").on(table.minUserId, table.maxUserId),

    /** Ensure unique space thread number */
    spaceThreadNumberUniqueContraint: unique("space_thread_number_unique").on(table.spaceId, table.threadNumber),

    /** Ensure maxMsgId is valid */
    maxMsgIdForeignKey: foreignKey({
      name: "max_msg_id_fk",
      columns: [table.id, table.maxMsgId],
      foreignColumns: [messages.chatId, messages.messageId],
    }).onDelete("set null"),
  }),
)

export type DbChat = typeof chats.$inferSelect
export type DbNewChat = typeof chats.$inferInsert
