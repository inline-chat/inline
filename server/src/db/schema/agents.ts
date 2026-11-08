import { bytea } from "@in/server/db/schema/common"
import { chats } from "@in/server/db/schema/chats"
import { users } from "@in/server/db/schema/users"
import { spaces } from "@in/server/db/schema/spaces"
import { userGroups } from "@in/server/db/schema/userGroups"
import {
  bigint,
  bigserial,
  check,
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
  // Mirror of agent_settings.default_output_mode for bridges that read it from
  // the runtime; agent_settings is the source of truth.
  defaultOutputMode: smallint("default_output_mode").default(0).notNull(),
  lastSeenAt: timestamp("last_seen_at", { mode: "date", precision: 3 }).notNull(),
  createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
})

/**
 * Per-bot settings from Agent Settings, read by the bot's harness. One row per
 * bot, created on first change; a missing row means every setting is default.
 */
export const agentSettings = pgTable("agent_settings", {
  botUserId: integer("bot_user_id")
    .primaryKey()
    .references(() => users.id, { onDelete: "cascade" }),
  // AgentOutputMode; 0 means Detailed.
  defaultOutputMode: smallint("default_output_mode").default(0).notNull(),
  revision: bigint("revision", { mode: "bigint" }).default(sql`1`).notNull(),
  updatedBy: integer("updated_by").references(() => users.id, { onDelete: "set null" }),
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
    // Exactly one subject: a person, everyone in a space, or everyone in a user group.
    subjectUserId: integer("subject_user_id").references(() => users.id, { onDelete: "cascade" }),
    subjectSpaceId: integer("subject_space_id").references(() => spaces.id, { onDelete: "cascade" }),
    subjectGroupId: integer("subject_group_id").references(() => userGroups.id, { onDelete: "cascade" }),
    // Bit (1 << AgentGrantOperation) per granted operation; 0 once revoked.
    operations: integer("operations").notNull(),
    revision: bigint("revision", { mode: "bigint" }).notNull(),
    grantedBy: integer("granted_by").references(() => users.id, { onDelete: "set null" }),
    revokedAt: timestamp("revoked_at", { mode: "date", precision: 3 }),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => [
    uniqueIndex("agent_grants_bot_subject_unique")
      .on(table.botUserId, table.subjectUserId)
      .where(sql`${table.subjectUserId} is not null`),
    uniqueIndex("agent_grants_bot_space_unique")
      .on(table.botUserId, table.subjectSpaceId)
      .where(sql`${table.subjectSpaceId} is not null`),
    uniqueIndex("agent_grants_bot_group_unique")
      .on(table.botUserId, table.subjectGroupId)
      .where(sql`${table.subjectGroupId} is not null`),
    index("agent_grants_subject_idx").on(table.subjectUserId),
    index("agent_grants_subject_space_idx").on(table.subjectSpaceId),
    index("agent_grants_subject_group_idx").on(table.subjectGroupId),
    check(
      "agent_grants_one_subject",
      sql`num_nonnulls(${table.subjectUserId}, ${table.subjectSpaceId}, ${table.subjectGroupId}) = 1`,
    ),
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
export type DbAgentSettings = typeof agentSettings.$inferSelect
export type DbAgentGrant = typeof agentGrants.$inferSelect
export type DbAgentParticipation = typeof agentParticipations.$inferSelect
