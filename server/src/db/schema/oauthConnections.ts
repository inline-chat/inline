import { sql } from "drizzle-orm"
import { check, index, integer, pgTable, serial, text, timestamp, uniqueIndex, varchar } from "drizzle-orm/pg-core"
import { bytea, creationDate } from "@in/server/db/schema/common"
import { spaces } from "@in/server/db/schema/spaces"
import { users } from "@in/server/db/schema/users"

export const oauthConnections = pgTable(
  "oauth_connections",
  {
    id: serial("id").primaryKey(),

    provider: varchar("provider", { length: 64 }).notNull(),
    scopeType: varchar("scope_type", { length: 16 }).notNull(),
    userId: integer("user_id").references(() => users.id, { onDelete: "cascade" }),
    spaceId: integer("space_id").references(() => spaces.id, { onDelete: "cascade" }),
    connectedByUserId: integer("connected_by_user_id")
      .notNull()
      .references(() => users.id),

    credentialCiphertext: bytea("credential_ciphertext").notNull(),
    identityCiphertext: bytea("identity_ciphertext"),
    configCiphertext: bytea("config_ciphertext"),

    status: varchar("status", { length: 32 }).notNull().default("active"),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }),
    lastRefreshAt: timestamp("last_refresh_at", { mode: "date", precision: 3 }),
    lastUsedAt: timestamp("last_used_at", { mode: "date", precision: 3 }),
    revokedAt: timestamp("revoked_at", { mode: "date", precision: 3 }),
    errorAt: timestamp("error_at", { mode: "date", precision: 3 }),
    errorCode: varchar("error_code", { length: 128 }),
    errorMessage: text("error_message"),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    date: creationDate,
  },
  (table) => ({
    providerUserUnique: uniqueIndex("oauth_connections_provider_user_unique").on(
      table.provider,
      table.scopeType,
      table.userId,
    ).where(sql`${table.status} = 'active'`),
    providerSpaceUnique: uniqueIndex("oauth_connections_provider_space_unique").on(
      table.provider,
      table.scopeType,
      table.spaceId,
    ).where(sql`${table.status} = 'active'`),
    connectedByUserIdIdx: index("oauth_connections_connected_by_user_id_idx").on(table.connectedByUserId),
    userIdIdx: index("oauth_connections_user_id_idx").on(table.userId),
    spaceIdIdx: index("oauth_connections_space_id_idx").on(table.spaceId),
    statusExpiresAtIdx: index("oauth_connections_status_expires_at_idx").on(table.status, table.expiresAt),
    providerStatusIdx: index("oauth_connections_provider_status_idx").on(table.provider, table.status),
    scopeTypeCheck: check("oauth_connections_scope_type_check", sql`${table.scopeType} in ('user', 'space')`),
    statusCheck: check("oauth_connections_status_check", sql`${table.status} in ('active', 'error', 'revoked')`),
    scopeTargetCheck: check(
      "oauth_connections_scope_target_check",
      sql`(
        (${table.scopeType} = 'user' and ${table.userId} is not null and ${table.spaceId} is null)
        or (${table.scopeType} = 'space' and ${table.spaceId} is not null and ${table.userId} is null)
      )`,
    ),
  }),
)

export type DbOauthConnection = typeof oauthConnections.$inferSelect
export type DbNewOauthConnection = typeof oauthConnections.$inferInsert
