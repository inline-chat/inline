import { bigint, foreignKey, integer, pgTable, unique } from "drizzle-orm/pg-core"
import { chats } from "@in/server/db/schema/chats"
import { messages } from "@in/server/db/schema/messages"

export const subthreadParentMessages = pgTable(
  "subthread_parent_messages",
  {
    childChatId: integer("child_chat_id").primaryKey(),
    parentMessageGlobalId: bigint("parent_message_global_id", { mode: "bigint" }),
  },
  (table) => ({
    parentMessageUnique: unique("subthread_parent_messages_parent_message_unique").on(
      table.parentMessageGlobalId,
    ),
    childChatForeignKey: foreignKey({
      name: "subthread_parent_messages_child_chat_fk",
      columns: [table.childChatId],
      foreignColumns: [chats.id],
    }).onDelete("cascade"),
    parentMessageForeignKey: foreignKey({
      name: "subthread_parent_messages_parent_message_fk",
      columns: [table.parentMessageGlobalId],
      foreignColumns: [messages.globalId],
    }).onDelete("set null"),
  }),
)

export type DbSubthreadParentMessage = typeof subthreadParentMessages.$inferSelect
export type DbNewSubthreadParentMessage = typeof subthreadParentMessages.$inferInsert
