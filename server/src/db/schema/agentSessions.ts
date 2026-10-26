import { bytea } from "@in/server/db/schema/common"
import { chats } from "@in/server/db/schema/chats"
import { messages } from "@in/server/db/schema/messages"
import { users } from "@in/server/db/schema/users"
import {
  bigserial,
  bigint,
  boolean,
  index,
  integer,
  pgTable,
  smallint,
  timestamp,
  uniqueIndex,
  type AnyPgColumn,
} from "drizzle-orm/pg-core"
import { sql } from "drizzle-orm"

export const agentSessions = pgTable(
  "agent_sessions",
  {
    id: bigserial("id", { mode: "bigint" }).primaryKey(),
    chatId: integer("chat_id")
      .notNull()
      .references(() => chats.id, { onDelete: "cascade" }),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    ownerUserId: integer("owner_user_id")
      .notNull()
      .references(() => users.id),
    provider: smallint("provider").notNull(),
    sessionKeyHash: bytea("session_key_hash").notNull(),
    instanceRefEncrypted: bytea("instance_ref_encrypted").notNull(),
    sessionRefEncrypted: bytea("session_ref_encrypted").notNull(),
    projectRefEncrypted: bytea("project_ref_encrypted"),
    statusMessageGlobalId: bigint("status_message_global_id", { mode: "bigint" })
      .references(() => messages.globalId, { onDelete: "set null" }),
    // Bridge v2. The encrypted project_ref is the session's workspace identity.
    parentSessionId: bigint("parent_session_id", { mode: "bigint" })
      .references((): AnyPgColumn => agentSessions.id, { onDelete: "set null" }),
    relation: smallint("relation").default(0).notNull(),
    workspaceLabelEncrypted: bytea("workspace_label_encrypted"),
    // Thin run state. The full AgentSessionState is in state_encrypted; these
    // plaintext copies only serve queries and push targeting.
    runState: smallint("run_state").default(0).notNull(),
    attentionKind: smallint("attention_kind").default(0).notNull(),
    attentionUserIds: integer("attention_user_ids").array(),
    heldBy: smallint("held_by").default(0).notNull(),
    stateRevision: bigint("state_revision", { mode: "bigint" }).default(sql`0`).notNull(),
    stateEncrypted: bytea("state_encrypted"),
    stateUpdatedAt: timestamp("state_updated_at", { mode: "date", precision: 3 }),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    externalSessionUnique: uniqueIndex("agent_sessions_external_unique").on(
      table.botUserId,
      table.provider,
      table.sessionKeyHash,
    ),
    // Bridge v2 allows several sessions per (chat, bot), for example after /new.
    chatBotIndex: index("agent_sessions_chat_bot_idx").on(table.chatId, table.botUserId, table.id),
    activeStateIndex: index("agent_sessions_active_state_idx")
      .on(table.chatId)
      .where(sql`${table.runState} not in (0, 1)`),
    parentIndex: index("agent_sessions_parent_idx")
      .on(table.parentSessionId)
      .where(sql`${table.parentSessionId} is not null`),
    ownerIndex: index("agent_sessions_owner_idx").on(table.ownerUserId),
    statusMessageUnique: uniqueIndex("agent_sessions_status_message_unique")
      .on(table.statusMessageGlobalId)
      .where(sql`${table.statusMessageGlobalId} is not null`),
  }),
)

export const agentSessionMessages = pgTable(
  "agent_session_messages",
  {
    id: bigserial("id", { mode: "bigint" }).primaryKey(),
    agentSessionId: bigint("agent_session_id", { mode: "bigint" })
      .notNull()
      .references(() => agentSessions.id, { onDelete: "cascade" }),
    sourceKeyHash: bytea("source_key_hash").notNull(),
    itemKeyHash: bytea("item_key_hash"),
    sourceRefEncrypted: bytea("source_ref_encrypted").notNull(),
    revisionRefEncrypted: bytea("revision_ref_encrypted"),
    messageGlobalId: bigint("message_global_id", { mode: "bigint" })
      .references(() => messages.globalId, { onDelete: "set null" }),
    relation: smallint("relation").notNull(),
    role: smallint("role").notNull(),
    complete: boolean("complete").default(false).notNull(),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    sourceUnique: uniqueIndex("agent_session_messages_source_unique").on(
      table.agentSessionId,
      table.sourceKeyHash,
    ),
    itemUnique: uniqueIndex("agent_session_messages_item_unique")
      .on(table.agentSessionId, table.itemKeyHash)
      .where(sql`${table.itemKeyHash} is not null`),
    messageUnique: uniqueIndex("agent_session_messages_message_unique")
      .on(table.agentSessionId, table.messageGlobalId)
      .where(sql`${table.messageGlobalId} is not null`),
  }),
)

export type DbAgentSession = typeof agentSessions.$inferSelect
export type DbAgentSessionMessage = typeof agentSessionMessages.$inferSelect
