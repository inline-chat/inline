import { sql } from "drizzle-orm"
import {
  check,
  index,
  integer,
  pgTable,
  primaryKey,
  serial,
  timestamp,
  uniqueIndex,
} from "drizzle-orm/pg-core"
import { bytea } from "./common"
import { spaces } from "./spaces"
import { users } from "./users"

export const spaceInviteLinks = pgTable(
  "space_invite_links",
  {
    id: serial("id").primaryKey(),
    spaceId: integer("space_id")
      .notNull()
      .references(() => spaces.id, { onDelete: "cascade" }),
    tokenHash: bytea("token_hash").notNull(),
    tokenEncrypted: bytea("token_encrypted").notNull(),
    createdByUserId: integer("created_by_user_id").references(() => users.id, {
      onDelete: "set null",
    }),
    createdAt: timestamp("created_at", { mode: "date", withTimezone: true }).defaultNow().notNull(),
    expiresAt: timestamp("expires_at", { mode: "date", withTimezone: true }).notNull(),
    revokedAt: timestamp("revoked_at", { mode: "date", withTimezone: true }),
  },
  (table) => [
    uniqueIndex("space_invite_links_token_hash_unique").on(table.tokenHash),
    uniqueIndex("space_invite_links_active_space_unique")
      .on(table.spaceId)
      .where(sql`${table.revokedAt} is null`),
    index("space_invite_links_space_id_idx").on(table.spaceId),
    index("space_invite_links_created_by_user_id_idx").on(table.createdByUserId),
    check("space_invite_links_token_hash_length", sql`octet_length(${table.tokenHash}) = 32`),
    check("space_invite_links_expiry_check", sql`${table.expiresAt} > ${table.createdAt}`),
  ],
)

export const spaceJoinBlocks = pgTable(
  "space_join_blocks",
  {
    spaceId: integer("space_id")
      .notNull()
      .references(() => spaces.id, { onDelete: "cascade" }),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at", { mode: "date", withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    primaryKey({ name: "space_join_blocks_pkey", columns: [table.spaceId, table.userId] }),
    index("space_join_blocks_user_id_idx").on(table.userId),
  ],
)

export type DbSpaceInviteLink = typeof spaceInviteLinks.$inferSelect
export type DbNewSpaceInviteLink = typeof spaceInviteLinks.$inferInsert
export type DbSpaceJoinBlock = typeof spaceJoinBlocks.$inferSelect
