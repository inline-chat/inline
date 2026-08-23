import { bytea } from "./common"
import { users } from "./users"
import {
  bigint,
  index,
  integer,
  jsonb,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"

const createdAt = () =>
  timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull()
const updatedAt = () =>
  timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull()

export const botUpdateStreams = pgTable("bot_update_streams", {
  botUserId: integer("bot_user_id")
    .primaryKey()
    .references(() => users.id, { onDelete: "cascade" }),
  nextUpdateId: bigint("next_update_id", { mode: "number" }).notNull(),
  acknowledgedUpdateId: bigint("acknowledged_update_id", { mode: "number" }).default(0).notNull(),
  allowedUpdates: jsonb("allowed_updates").$type<string[]>().notNull(),
  messageTrigger: varchar("message_trigger", { length: 16 }).default("mentions").notNull(),
  webhookUrl: text("webhook_url"),
  webhookSecretEncrypted: bytea("webhook_secret_encrypted"),
  pollLeaseToken: varchar("poll_lease_token", { length: 64 }),
  pollLeaseExpiresAt: timestamp("poll_lease_expires_at", { mode: "date", precision: 3 }),
  configGeneration: bigint("config_generation", { mode: "number" }).default(1).notNull(),
  pendingUpdateCount: integer("pending_update_count").default(0).notNull(),
  pendingPayloadBytes: bigint("pending_payload_bytes", { mode: "number" }).default(0).notNull(),
  // Legacy stream-head delivery fields. New webhook delivery state is per update.
  nextAttemptAt: timestamp("next_attempt_at", { mode: "date", precision: 3 }),
  attemptCount: integer("attempt_count").default(0).notNull(),
  deliveryLockedAt: timestamp("delivery_locked_at", { mode: "date", precision: 3 }),
  lastErrorAt: timestamp("last_error_at", { mode: "date", precision: 3 }),
  lastErrorMessage: text("last_error_message"),
  droppedUpdateCount: integer("dropped_update_count").default(0).notNull(),
  createdAt: createdAt(),
  updatedAt: updatedAt(),
})

export const botUpdates = pgTable(
  "bot_updates",
  {
    id: bigint("id", { mode: "number" }).primaryKey().generatedAlwaysAsIdentity(),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    updateId: bigint("update_id", { mode: "number" }).notNull(),
    updateType: varchar("update_type", { length: 32 }).notNull(),
    payloadEncrypted: bytea("payload_encrypted").notNull(),
    payloadByteCount: integer("payload_byte_count").default(0).notNull(),
    sourceEventId: varchar("source_event_id", { length: 160 }),
    claimToken: varchar("claim_token", { length: 64 }),
    claimGeneration: bigint("claim_generation", { mode: "number" }),
    claimExpiresAt: timestamp("claim_expires_at", { mode: "date", precision: 3 }),
    nextAttemptAt: timestamp("next_attempt_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    attemptCount: integer("attempt_count").default(0).notNull(),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    createdAt: createdAt(),
  },
  (table) => ({
    botUpdatesBotUpdateIdUnique: uniqueIndex("bot_updates_bot_update_id_unique").on(
      table.botUserId,
      table.updateId,
    ),
    botUpdatesBotSourceEventUnique: uniqueIndex("bot_updates_bot_source_event_unique").on(
      table.botUserId,
      table.sourceEventId,
    ),
    botUpdatesPendingIdx: index("bot_updates_pending_idx").on(
      table.botUserId,
      table.updateId,
      table.expiresAt,
    ),
    botUpdatesExpiryIdx: index("bot_updates_expiry_idx").on(table.expiresAt),
    botUpdatesDeliveryIdx: index("bot_updates_delivery_idx").on(
      table.nextAttemptAt,
      table.claimExpiresAt,
      table.expiresAt,
      table.botUserId,
      table.updateId,
    ),
  }),
)

export const botMessageRoutes = pgTable(
  "bot_message_routes",
  {
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    chatId: integer("chat_id").notNull(),
    messageId: integer("message_id").notNull(),
    activationReason: varchar("activation_reason", { length: 16 }).notNull(),
    createdAt: createdAt(),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
  },
  (table) => ({
    botMessageRoutesIdentity: uniqueIndex("bot_message_routes_identity_unique").on(
      table.botUserId,
      table.chatId,
      table.messageId,
    ),
    botMessageRoutesMessageIdx: index("bot_message_routes_message_idx").on(
      table.chatId,
      table.messageId,
      table.botUserId,
    ),
    botMessageRoutesExpiryIdx: index("bot_message_routes_expiry_idx").on(table.expiresAt),
  }),
)

export type DbBotUpdateStream = typeof botUpdateStreams.$inferSelect
export type DbBotUpdate = typeof botUpdates.$inferSelect
