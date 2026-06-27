import { sql } from "drizzle-orm"
import {
  bigserial,
  bigint,
  foreignKey,
  index,
  integer,
  pgEnum,
  pgTable,
  timestamp,
  unique,
  varchar,
} from "drizzle-orm/pg-core"
import { bytea, creationDate } from "@in/server/db/schema/common"
import { chats } from "@in/server/db/schema/chats"
import { messages } from "@in/server/db/schema/messages"

export const threadGraphLinkKindEnum = pgEnum("thread_graph_link_kind", ["thread_link", "reply_thread"])
export const threadGraphScopeTypeEnum = pgEnum("thread_graph_scope_type", ["user", "space"])

export const threadGraphLinks = pgTable(
  "thread_graph_links",
  {
    id: bigserial("id", { mode: "bigint" }).primaryKey(),
    dedupeKey: varchar("dedupe_key", { length: 255 }).notNull(),
    kind: threadGraphLinkKindEnum().notNull(),
    scopeType: threadGraphScopeTypeEnum("scope_type").notNull(),
    scopeId: integer("scope_id").notNull(),

    fromChatId: integer("from_chat_id").notNull(),
    fromMessageGlobalId: bigint("from_message_global_id", { mode: "bigint" }),
    fromMessageId: integer("from_message_id"),
    fromMessageRevision: integer("from_message_revision"),
    entityIndex: integer("entity_index"),

    toChatId: integer("to_chat_id").notNull(),
    backlinkMessageGlobalId: bigint("backlink_message_global_id", { mode: "bigint" }),

    linkTextHmac: bytea("link_text_hmac"),
    targetTitleHmac: bytea("target_title_hmac"),
    deletedAt: timestamp("deleted_at", { mode: "date", precision: 3 }),
    date: creationDate,
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 })
      .defaultNow()
      .notNull(),
  },
  (table) => ({
    dedupeKeyUnique: unique("thread_graph_links_dedupe_key_unique").on(table.dedupeKey),
    scopeToChatIndex: index("thread_graph_links_scope_to_chat_idx").on(table.scopeType, table.scopeId, table.toChatId),
    scopeFromChatIndex: index("thread_graph_links_scope_from_chat_idx").on(
      table.scopeType,
      table.scopeId,
      table.fromChatId,
    ),
    fromMessageIndex: index("thread_graph_links_from_message_idx").on(table.fromMessageGlobalId),
    backlinkMessageIndex: index("thread_graph_links_backlink_message_idx").on(table.backlinkMessageGlobalId),
    activeRowsIndex: index("thread_graph_links_active_idx")
      .on(table.kind, table.toChatId)
      .where(sql`${table.deletedAt} is null`),
    fromChatForeignKey: foreignKey({
      name: "tgl_from_chat_fk",
      columns: [table.fromChatId],
      foreignColumns: [chats.id],
    }).onDelete("cascade"),
    fromMessageForeignKey: foreignKey({
      name: "tgl_from_message_fk",
      columns: [table.fromMessageGlobalId],
      foreignColumns: [messages.globalId],
    }).onDelete("cascade"),
    toChatForeignKey: foreignKey({
      name: "tgl_to_chat_fk",
      columns: [table.toChatId],
      foreignColumns: [chats.id],
    }).onDelete("cascade"),
    backlinkMessageForeignKey: foreignKey({
      name: "tgl_backlink_message_fk",
      columns: [table.backlinkMessageGlobalId],
      foreignColumns: [messages.globalId],
    }).onDelete("set null"),
  }),
)

export type DbThreadGraphLink = typeof threadGraphLinks.$inferSelect
export type DbNewThreadGraphLink = typeof threadGraphLinks.$inferInsert
