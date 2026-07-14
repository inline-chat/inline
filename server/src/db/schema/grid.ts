import { sessions } from "@in/server/db/schema/sessions"
import { spaces } from "@in/server/db/schema/spaces"
import { lower, users } from "@in/server/db/schema/users"
import { sql } from "drizzle-orm"
import { boolean, check, index, integer, pgTable, serial, timestamp, uniqueIndex, uuid, varchar } from "drizzle-orm/pg-core"

export const gridRooms = pgTable(
  "grid_rooms",
  {
    id: serial().primaryKey(),
    spaceId: integer("space_id")
      .notNull()
      .references(() => spaces.id, { onDelete: "cascade" }),
    createdByUserId: integer("created_by_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "restrict" }),
    title: varchar("title", { length: 80 }),
    locked: boolean("locked").default(false).notNull(),
    connectionGeneration: integer("connection_generation").default(0).notNull(),
    connectionStartedAt: timestamp("connection_started_at", { mode: "date", precision: 3 }),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 })
      .defaultNow()
      .notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 })
      .defaultNow()
      .notNull(),
  },
  (table) => ({
    spaceIndex: index("grid_rooms_space_id_idx").on(table.spaceId),
    creatorIndex: index("grid_rooms_created_by_user_id_idx").on(table.createdByUserId),
    namedRoomUnique: uniqueIndex("grid_rooms_space_title_unique")
      .on(table.spaceId, lower(table.title))
      .where(sql`${table.title} is not null`),
    connectionGenerationCheck: check(
      "grid_rooms_connection_generation_check",
      sql`${table.connectionGeneration} >= 0`,
    ),
    titleNotEmptyCheck: check("grid_rooms_title_not_empty_check", sql`${table.title} is null or length(${table.title}) > 0`),
  }),
)

export const gridPresence = pgTable(
  "grid_presence",
  {
    userId: integer("user_id")
      .primaryKey()
      .references(() => users.id, { onDelete: "cascade" }),
    roomId: integer("room_id")
      .notNull()
      .references(() => gridRooms.id, { onDelete: "cascade" }),
    ownerSessionId: integer("owner_session_id")
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    joinedAt: timestamp("joined_at", { mode: "date", precision: 3 })
      .defaultNow()
      .notNull(),
    microphoneEnabled: boolean("microphone_enabled").default(false).notNull(),
    microphoneRevision: integer("microphone_revision").default(0).notNull(),
    mediaMembershipId: uuid("media_membership_id").defaultRandom().notNull(),
    leaseExpiresAt: timestamp("lease_expires_at", { mode: "date", precision: 3 }).notNull(),
  },
  (table) => ({
    roomIndex: index("grid_presence_room_id_idx").on(table.roomId),
    ownerSessionIndex: index("grid_presence_owner_session_id_idx").on(table.ownerSessionId),
    leaseExpiryIndex: index("grid_presence_lease_expires_at_idx").on(table.leaseExpiresAt),
    microphoneRevisionCheck: check(
      "grid_presence_microphone_revision_check",
      sql`${table.microphoneRevision} >= 0`,
    ),
  }),
)

/**
 * Durable side effects for the external Grid media provider. Rows are written
 * in the same transaction as authoritative room/presence changes, then leased
 * by a background worker after commit. Room and user foreign keys are omitted
 * intentionally: cleanup must survive deletion of the source records.
 */
export const gridProviderEffects = pgTable(
  "grid_provider_effects",
  {
    id: serial().primaryKey(),
    kind: varchar("kind", { length: 32 }).notNull(),
    deduplicationKey: varchar("deduplication_key", { length: 128 }).notNull(),
    roomId: integer("room_id").notNull(),
    connectionGeneration: integer("connection_generation").notNull(),
    userId: integer("user_id"),
    participantIdentity: varchar("participant_identity", { length: 128 }),
    availableAt: timestamp("available_at", { mode: "date", precision: 3 }).notNull(),
    attempts: integer("attempts").default(0).notNull(),
    claimToken: varchar("claim_token", { length: 64 }),
    claimExpiresAt: timestamp("claim_expires_at", { mode: "date", precision: 3 }),
    lastError: varchar("last_error", { length: 500 }),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 })
      .defaultNow()
      .notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 })
      .defaultNow()
      .notNull(),
  },
  (table) => ({
    deduplicationUnique: uniqueIndex("grid_provider_effects_deduplication_key_unique").on(
      table.deduplicationKey,
    ),
    readyIndex: index("grid_provider_effects_ready_idx").on(table.availableAt, table.claimExpiresAt),
    kindCheck: check(
      "grid_provider_effects_kind_check",
      sql`${table.kind} in ('close_connection', 'revoke_participant')`,
    ),
    generationCheck: check(
      "grid_provider_effects_connection_generation_check",
      sql`${table.connectionGeneration} >= 0`,
    ),
    attemptsCheck: check("grid_provider_effects_attempts_check", sql`${table.attempts} >= 0`),
    participantCheck: check(
      "grid_provider_effects_participant_check",
      sql`(${table.kind} = 'revoke_participant' and ${table.userId} is not null) or (${table.kind} = 'close_connection' and ${table.userId} is null)`,
    ),
  }),
)

export type DbGridRoom = typeof gridRooms.$inferSelect
export type DbNewGridRoom = typeof gridRooms.$inferInsert
export type DbGridPresence = typeof gridPresence.$inferSelect
export type DbNewGridPresence = typeof gridPresence.$inferInsert
export type DbGridProviderEffect = typeof gridProviderEffects.$inferSelect
export type DbNewGridProviderEffect = typeof gridProviderEffects.$inferInsert
