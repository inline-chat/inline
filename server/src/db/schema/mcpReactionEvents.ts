import { bytea, index, integer, pgTable, primaryKey, timestamp } from "drizzle-orm/pg-core"
import { chats } from "./chats"

/** Explicit reaction transitions only; no FK to current messages or actors. */
export const mcpReactionEvents = pgTable("mcp_reaction_events", {
  chatId: integer("chat_id").notNull().references(() => chats.id, { onDelete: "cascade" }),
  seq: integer("seq").notNull(),
  occurredAt: timestamp("occurred_at", { mode: "date", precision: 3 }).notNull(),
  payloadEncrypted: bytea("payload_encrypted").notNull(),
}, (table) => [
  primaryKey({ columns: [table.chatId, table.seq] }),
  index("mcp_reactions_retention_idx").on(table.occurredAt, table.chatId, table.seq),
])
