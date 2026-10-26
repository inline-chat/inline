import { bytea } from "@in/server/db/schema/common"
import { agentSessions } from "@in/server/db/schema/agentSessions"
import { chats } from "@in/server/db/schema/chats"
import { users } from "@in/server/db/schema/users"
import {
  bigint,
  bigserial,
  index,
  integer,
  pgSequence,
  pgTable,
  smallint,
  text,
  timestamp,
  uniqueIndex,
} from "drizzle-orm/pg-core"
import { sql } from "drizzle-orm"

/** One bridge runtime per bot: one bot per machine per provider. */
export const agentRuntimes = pgTable("agent_runtimes", {
  botUserId: integer("bot_user_id")
    .primaryKey()
    .references(() => users.id, { onDelete: "cascade" }),
  provider: smallint("provider").notNull(),
  status: smallint("status").notNull(),
  setupReason: smallint("setup_reason"),
  setupText: text("setup_text"),
  setupMinVersion: text("setup_min_version"),
  machineLabel: text("machine_label"),
  executablePathEncrypted: bytea("executable_path_encrypted"),
  executableVersion: text("executable_version"),
  manifestHash: text("manifest_hash"),
  bridgeVersion: text("bridge_version"),
  // AgentOutputMode set in Agent Settings; 0 means Detailed.
  defaultOutputMode: smallint("default_output_mode").default(0).notNull(),
  lastSeenAt: timestamp("last_seen_at", { mode: "date", precision: 3 }).notNull(),
  createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
})

/** Monotonic across all bots so a bot's grant revision never moves backwards. */
export const agentGrantRevisionSequence = pgSequence("agent_grant_revision")

/**
 * Opt-in access to a bot. No active rows means owner-only. Revoked rows stay
 * with a new revision so the bot's grant revision covers deletions too.
 */
export const agentGrants = pgTable(
  "agent_grants",
  {
    id: bigserial("id", { mode: "bigint" }).primaryKey(),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    subjectUserId: integer("subject_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    // Bit (1 << AgentGrantOperation) per granted operation; 0 once revoked.
    operations: integer("operations").notNull(),
    revision: bigint("revision", { mode: "bigint" }).notNull(),
    grantedBy: integer("granted_by").references(() => users.id, { onDelete: "set null" }),
    revokedAt: timestamp("revoked_at", { mode: "date", precision: 3 }),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => [
    uniqueIndex("agent_grants_bot_subject_unique").on(table.botUserId, table.subjectUserId),
    index("agent_grants_subject_idx").on(table.subjectUserId),
  ],
)

/** How one agent takes part in one chat. */
export const agentParticipations = pgTable(
  "agent_participations",
  {
    id: bigserial("id", { mode: "bigint" }).primaryKey(),
    chatId: integer("chat_id")
      .notNull()
      .references(() => chats.id, { onDelete: "cascade" }),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    mode: smallint("mode").notNull(),
    // Per-thread AgentOutputMode override; null uses the agent default.
    outputMode: smallint("output_mode"),
    joinedBy: integer("joined_by").references(() => users.id, { onDelete: "set null" }),
    defaultSessionId: bigint("default_session_id", { mode: "bigint" })
      .references(() => agentSessions.id, { onDelete: "set null" }),
    revision: bigint("revision", { mode: "bigint" }).default(sql`1`).notNull(),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => [
    uniqueIndex("agent_participations_chat_bot_unique").on(table.chatId, table.botUserId),
    index("agent_participations_bot_idx").on(table.botUserId),
  ],
)

export type DbAgentRuntime = typeof agentRuntimes.$inferSelect
export type DbAgentGrant = typeof agentGrants.$inferSelect
export type DbAgentParticipation = typeof agentParticipations.$inferSelect
