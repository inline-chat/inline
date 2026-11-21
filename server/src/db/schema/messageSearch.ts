import { bigint, boolean, check, index, integer, pgSequence, pgTable, text, timestamp, uuid } from "drizzle-orm/pg-core"
import { sql } from "drizzle-orm"
import { bytea } from "./common"
import { chats } from "./chats"
import { messages } from "./messages"

export const messageSearchWorkVersion = pgSequence("message_search_work_version")

/** Independent random search keys; only authenticated ciphertext is stored. */
export const chatSearchKeys = pgTable("chat_search_keys", {
  chatId: integer("chat_id")
    .primaryKey()
    .references(() => chats.id, { onDelete: "cascade" }),
  keyEnvelope: bytea("key_envelope").notNull(),
})

/** Also the durable coalescing indexing queue. No message or query text belongs here. */
export const messageSearchDocuments = pgTable(
  "message_search_documents",
  {
    messageGlobalId: bigint("message_global_id", { mode: "bigint" })
      .primaryKey()
      .references(() => messages.globalId, { onDelete: "cascade" }),
    chatId: integer("chat_id").notNull(),
    messageRev: integer("message_rev").notNull(),
    workVersion: bigint("work_version", { mode: "bigint" })
      .notNull()
      .default(sql`nextval('message_search_work_version')`),
    tokenizerVersion: text("tokenizer_version"),
    historical: boolean("historical").notNull().default(false),
    failedAttempts: integer("failed_attempts").notNull().default(0),
    claimUntil: timestamp("claim_until", { withTimezone: true }),
    ready: boolean("ready").notNull().default(false),
    // Large documents remain fully searchable by bounded candidate verification.
    overflow: boolean("overflow").notNull().default(false),
    tags: uuid("tags")
      .array()
      .notNull()
      .default(sql`'{}'::uuid[]`),
  },
  (table) => ({
    readyMetadata: check(
      "message_search_ready_metadata",
      sql`not ${table.ready} or
      (${table.tokenizerVersion} is not null and ${table.claimUntil} is null)`,
    ),
    overflowTags: check("message_search_overflow_tags", sql`not ${table.overflow} or cardinality(${table.tags}) = 0`),
    pendingIndex: index("message_search_pending_idx")
      .on(table.historical, table.messageGlobalId)
      .where(sql`not ${table.ready} and ${table.failedAttempts} < 5`),
    pendingChatIndex: index("message_search_pending_chat_idx")
      .on(table.chatId, table.messageGlobalId)
      .where(sql`not ${table.ready}`),
    profileIndex: index("message_search_profile_idx")
      .on(table.tokenizerVersion, table.chatId)
      .where(sql`${table.ready}`),
    overflowIndex: index("message_search_overflow_idx")
      .on(table.messageGlobalId)
      .where(sql`${table.ready} and ${table.overflow}`),
    tagsIndex: index("message_search_tags_idx").using("gin", table.tags),
  }),
)

/** Checkpoint for historical rows. New writes are captured by database triggers. */
export const messageSearchBackfill = pgTable("message_search_backfill", {
  profile: text("profile").primaryKey(),
  afterGlobalId: bigint("after_global_id", { mode: "bigint" })
    .notNull()
    .default(sql`0`),
  complete: boolean("complete").notNull().default(false),
})
