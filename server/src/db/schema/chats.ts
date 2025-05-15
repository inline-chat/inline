import { pgTable, varchar, boolean, pgEnum, unique, check } from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { sql } from "drizzle-orm"
import { relations } from "drizzle-orm/_relations"
import { creationDate } from "@in/server/db/schema/common"
import { integer } from "drizzle-orm/pg-core"
import { messages } from "@in/server/db/schema/messages"
import { foreignKey } from "drizzle-orm/pg-core"
import { text } from "drizzle-orm/pg-core"
import { dialogs } from "@in/server/db/schema/dialogs"

export const chatTypeEnum = pgEnum("chat_types", ["private", "thread"])

export const chats = pgTable(
  "chats",
  {
    id: integer().primaryKey().generatedAlwaysAsIdentity(),
    type: chatTypeEnum().notNull(),
    title: varchar({ length: 150 }),
    description: text(),

    /** Most recent message id */
    lastMsgId: integer("last_msg_id"),

    /** optional, if part of a space */
    spaceId: integer("space_id").references(() => spaces.id),

    /** optional, required for space chats, defaults to false */
    publicThread: boolean("public_thread"),

    /** optional, required for space chats, thread number */
    threadNumber: integer("thread_number"),

    /** optional, required for private chats, least user id */
    minUserId: integer("min_user_id").references(() => users.id),
    /** optional, required for private chats, greatest user id */
    maxUserId: integer("max_user_id").references(() => users.id),

    // /** required for updates sequence */
    // pts: integer(),

    date: creationDate,
    emoji: varchar({ length: 20 }),
  },
  (table) => ({
    /** Ensure correctness */
    userIdsCheckConstraint: check("user_ids_check", sql`${table.minUserId} <= ${table.maxUserId}`),
    /** Ensure single private chat exists for each user pair */
    userIdsUniqueContraint: unique("user_ids_unique").on(table.minUserId, table.maxUserId),

    /** Ensure unique space thread number */
    spaceThreadNumberUniqueContraint: unique("space_thread_number_unique").on(table.spaceId, table.threadNumber),

    /** Ensure lastMsgId is valid */
    lastMsgIdForeignKey: foreignKey({
      name: "last_msg_id_fk",
      columns: [table.id, table.lastMsgId],
      foreignColumns: [messages.chatId, messages.messageId],
    }),
  }),
)

export const chatParticipants = pgTable(
  "chat_participants",
  {
    id: integer().primaryKey().generatedAlwaysAsIdentity(),
    chatId: integer("chat_id")
      .references(() => chats.id)
      .notNull(),
    userId: integer("user_id")
      .references(() => users.id)
      .notNull(),
    date: creationDate,
  },
  (table) => ({
    /** Ensure unique participant per chat */
    uniqueParticipant: unique("unique_participant").on(table.chatId, table.userId),
  }),
)

export const chatsRelations = relations(chats, ({ one, many }) => ({
  space: one(spaces, {
    fields: [chats.spaceId],
    references: [spaces.id],
  }),

  lastMsg: one(messages, {
    fields: [chats.id, chats.lastMsgId],
    references: [messages.chatId, messages.messageId],
  }),

  dialogs: many(dialogs),
  participants: many(chatParticipants),
}))

export const chatParticipantsRelations = relations(chatParticipants, ({ one }) => ({
  chat: one(chats, {
    fields: [chatParticipants.chatId],
    references: [chats.id],
  }),
  user: one(users, {
    fields: [chatParticipants.userId],
    references: [users.id],
  }),
}))

export type DbChat = typeof chats.$inferSelect
export type DbNewChat = typeof chats.$inferInsert
export type DbChatParticipant = typeof chatParticipants.$inferSelect
export type DbNewChatParticipant = typeof chatParticipants.$inferInsert
