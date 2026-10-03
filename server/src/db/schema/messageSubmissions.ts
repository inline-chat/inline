import { bigint, integer, pgTable, primaryKey } from "drizzle-orm/pg-core"
import { bytea } from "./common"
import { users } from "./users"

// Application submission identity outlives message deletion and transport
// sessions. Transport replay is session-scoped and expires completed results.
export const messageSubmissions = pgTable("message_submissions", {
  fromId: integer("from_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  randomId: bigint("random_id", { mode: "bigint" }).notNull(),
  // Encrypted canonical request digest; ordinary sends can contain private text.
  intentHash: bytea("intent_hash").notNull(),
  // Deliberately no Chat/Message FK: deletion must not erase a consumed identity.
  chatId: integer("chat_id").notNull(),
  messageId: integer("message_id").notNull(),
  // Non-null only for forwarding. Also fences ordinary/forwarded ID collisions.
  sourceRevision: integer("source_revision"),
}, (table) => [primaryKey({ name: "message_submissions_identity", columns: [table.fromId, table.randomId] })])
