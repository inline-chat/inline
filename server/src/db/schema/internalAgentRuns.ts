import { sql } from "drizzle-orm"
import {
  bigint,
  check,
  foreignKey,
  index,
  integer,
  pgTable,
  serial,
  text,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"
import { bytea, creationDate } from "@in/server/db/schema/common"
import { chats } from "@in/server/db/schema/chats"
import { messages } from "@in/server/db/schema/messages"
import { oauthConnections } from "@in/server/db/schema/oauthConnections"
import { spaces } from "@in/server/db/schema/spaces"
import { users } from "@in/server/db/schema/users"

export const internalAgentRuns = pgTable(
  "internal_agent_runs",
  {
    id: varchar("id", { length: 128 }).primaryKey(),
    agentKey: varchar("agent_key", { length: 64 }).notNull(),
    runKey: varchar("run_key", { length: 256 }).notNull(),

    scopeType: varchar("scope_type", { length: 16 }).notNull(),
    scopeUserId: integer("scope_user_id").references(() => users.id, { onDelete: "cascade" }),
    scopeSpaceId: integer("scope_space_id").references(() => spaces.id, { onDelete: "cascade" }),

    actorUserId: integer("actor_user_id")
      .notNull()
      .references(() => users.id),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id),
    chatId: integer("chat_id")
      .notNull()
      .references(() => chats.id, { onDelete: "cascade" }),
    threadRootMsgId: integer("thread_root_msg_id"),
    triggerMsgGlobalId: bigint("trigger_msg_global_id", { mode: "bigint" }).references(() => messages.globalId, {
      onDelete: "set null",
    }),
    outputMsgGlobalId: bigint("output_msg_global_id", { mode: "bigint" }).references(() => messages.globalId, {
      onDelete: "set null",
    }),
    connectionId: integer("connection_id").references(() => oauthConnections.id),

    status: varchar("status", { length: 32 }).notNull().default("pending"),
    attempt: integer("attempt").notNull().default(0),
    leaseOwner: varchar("lease_owner", { length: 128 }),
    leaseExpiresAt: timestamp("lease_expires_at", { mode: "date", precision: 3 }),
    heartbeatAt: timestamp("heartbeat_at", { mode: "date", precision: 3 }),
    startedAt: timestamp("started_at", { mode: "date", precision: 3 }),
    lastEditAt: timestamp("last_edit_at", { mode: "date", precision: 3 }),
    completedAt: timestamp("completed_at", { mode: "date", precision: 3 }),
    errorCode: varchar("error_code", { length: 128 }),
    errorMessage: text("error_message"),
    lastVisibleTextLength: integer("last_visible_text_length").notNull().default(0),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    date: creationDate,
  },
  (table) => ({
    agentRunKeyIdx: index("internal_agent_runs_agent_run_key_idx").on(table.agentKey, table.runKey),
    agentTriggerMsgUnique: uniqueIndex("internal_agent_runs_agent_trigger_msg_unique").on(
      table.agentKey,
      table.triggerMsgGlobalId,
    ),
    statusLeaseIdx: index("internal_agent_runs_status_lease_idx").on(table.status, table.leaseExpiresAt),
    chatStatusIdx: index("internal_agent_runs_chat_status_idx").on(table.chatId, table.status),
    actorUserIdIdx: index("internal_agent_runs_actor_user_id_idx").on(table.actorUserId),
    botUserIdIdx: index("internal_agent_runs_bot_user_id_idx").on(table.botUserId),
    connectionIdIdx: index("internal_agent_runs_connection_id_idx").on(table.connectionId),
    scopeUserIdIdx: index("internal_agent_runs_scope_user_id_idx").on(table.scopeUserId),
    scopeSpaceIdIdx: index("internal_agent_runs_scope_space_id_idx").on(table.scopeSpaceId),
    outputMsgGlobalIdIdx: index("internal_agent_runs_output_msg_global_id_idx").on(table.outputMsgGlobalId),
    scopeTypeCheck: check("internal_agent_runs_scope_type_check", sql`${table.scopeType} in ('user', 'space')`),
    statusCheck: check(
      "internal_agent_runs_status_check",
      sql`${table.status} in (
        'pending',
        'debouncing',
        'running',
        'streaming',
        'waiting_for_tool',
        'succeeded',
        'failed',
        'cancel_requested',
        'canceled',
        'interrupted'
      )`,
    ),
    scopeTargetCheck: check(
      "internal_agent_runs_scope_target_check",
      sql`(
        (${table.scopeType} = 'user' and ${table.scopeUserId} is not null and ${table.scopeSpaceId} is null)
        or (${table.scopeType} = 'space' and ${table.scopeSpaceId} is not null and ${table.scopeUserId} is null)
      )`,
    ),
  }),
)

export const internalAgentProviderStates = pgTable(
  "internal_agent_provider_states",
  {
    id: serial("id").primaryKey(),
    runId: varchar("run_id", { length: 128 })
      .notNull()
      .references(() => internalAgentRuns.id, { onDelete: "cascade" }),
    provider: varchar("provider", { length: 64 }).notNull(),
    issuer: varchar("issuer", { length: 128 }),
    model: varchar("model", { length: 128 }),
    responseId: varchar("response_id", { length: 256 }),
    connectionId: integer("connection_id"),
    outputMsgGlobalId: bigint("output_msg_global_id", { mode: "bigint" }),
    encryptedStateCiphertext: bytea("encrypted_state_ciphertext").notNull(),
    encryptedItemCount: integer("encrypted_item_count").notNull().default(0),
    date: creationDate,
  },
  (table) => ({
    runProviderUnique: uniqueIndex("internal_agent_provider_states_run_provider_unique").on(table.runId, table.provider),
    runIdIdx: index("internal_agent_provider_states_run_id_idx").on(table.runId),
    connectionIdIdx: index("internal_agent_provider_states_connection_id_idx").on(table.connectionId),
    outputMsgGlobalIdIdx: index("internal_agent_provider_states_output_msg_global_id_idx").on(table.outputMsgGlobalId),
    connectionFk: foreignKey({
      name: "internal_agent_provider_states_connection_fk",
      columns: [table.connectionId],
      foreignColumns: [oauthConnections.id],
    }),
    outputMsgFk: foreignKey({
      name: "internal_agent_provider_states_output_msg_fk",
      columns: [table.outputMsgGlobalId],
      foreignColumns: [messages.globalId],
    }).onDelete("cascade"),
  }),
)

export type DbInternalAgentRun = typeof internalAgentRuns.$inferSelect
export type DbNewInternalAgentRun = typeof internalAgentRuns.$inferInsert
export type DbInternalAgentProviderState = typeof internalAgentProviderStates.$inferSelect
export type DbNewInternalAgentProviderState = typeof internalAgentProviderStates.$inferInsert
