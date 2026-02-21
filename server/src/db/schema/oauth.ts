import { bytea, creationDate } from "@in/server/db/schema/common"
import { users } from "@in/server/db/schema/users"
import {
  boolean,
  index,
  integer,
  jsonb,
  pgTable,
  text,
  timestamp,
  varchar,
  uniqueIndex,
} from "drizzle-orm/pg-core"

export const oauthClients = pgTable(
  "oauth_clients",
  {
    clientId: varchar("client_id", { length: 128 }).primaryKey(),
    redirectUrisJson: text("redirect_uris_json").notNull(),
    clientName: text("client_name"),
    date: creationDate,
  },
  (table) => ({
    oauthClientsDateIdx: index("oauth_clients_date_idx").on(table.date),
  }),
)

export const oauthAuthRequests = pgTable(
  "oauth_auth_requests",
  {
    id: varchar("id", { length: 128 }).primaryKey(),
    clientId: varchar("client_id", { length: 128 })
      .notNull()
      .references(() => oauthClients.clientId),
    redirectUri: text("redirect_uri").notNull(),
    state: text("state").notNull(),
    scope: text("scope").notNull(),
    codeChallenge: text("code_challenge").notNull(),
    csrfToken: text("csrf_token").notNull(),
    deviceId: varchar("device_id", { length: 128 }).notNull(),
    email: varchar("email", { length: 256 }),
    challengeToken: varchar("challenge_token", { length: 128 }),
    inlineUserId: integer("inline_user_id").references(() => users.id),
    inlineTokenEncrypted: bytea("inline_token_encrypted"),
    date: creationDate,
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
  },
  (table) => ({
    oauthAuthRequestsExpiryIdx: index("oauth_auth_requests_expiry_idx").on(table.expiresAt),
    oauthAuthRequestsClientIdx: index("oauth_auth_requests_client_idx").on(table.clientId),
    oauthAuthRequestsChallengeUnique: uniqueIndex("oauth_auth_requests_challenge_unique").on(table.challengeToken),
  }),
)

export const oauthGrants = pgTable(
  "oauth_grants",
  {
    id: varchar("id", { length: 128 }).primaryKey(),
    clientId: varchar("client_id", { length: 128 })
      .notNull()
      .references(() => oauthClients.clientId),
    inlineUserId: integer("inline_user_id")
      .notNull()
      .references(() => users.id),
    scope: text("scope").notNull(),
    spaceIdsJson: jsonb("space_ids_json").$type<number[]>().notNull(),
    allowDms: boolean("allow_dms").default(false).notNull(),
    allowHomeThreads: boolean("allow_home_threads").default(false).notNull(),
    inlineTokenEncrypted: bytea("inline_token_encrypted").notNull(),
    date: creationDate,
    revokedAt: timestamp("revoked_at", { mode: "date", precision: 3 }),
  },
  (table) => ({
    oauthGrantsClientIdx: index("oauth_grants_client_idx").on(table.clientId),
    oauthGrantsInlineUserIdx: index("oauth_grants_inline_user_idx").on(table.inlineUserId),
    oauthGrantsRevokedIdx: index("oauth_grants_revoked_idx").on(table.revokedAt),
  }),
)

export const oauthAuthCodes = pgTable(
  "oauth_auth_codes",
  {
    code: varchar("code", { length: 256 }).primaryKey(),
    grantId: varchar("grant_id", { length: 128 })
      .notNull()
      .references(() => oauthGrants.id),
    clientId: varchar("client_id", { length: 128 })
      .notNull()
      .references(() => oauthClients.clientId),
    redirectUri: text("redirect_uri").notNull(),
    codeChallenge: text("code_challenge").notNull(),
    usedAt: timestamp("used_at", { mode: "date", precision: 3 }),
    date: creationDate,
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
  },
  (table) => ({
    oauthAuthCodesExpiryIdx: index("oauth_auth_codes_expiry_idx").on(table.expiresAt),
    oauthAuthCodesGrantIdx: index("oauth_auth_codes_grant_idx").on(table.grantId),
    oauthAuthCodesUsedIdx: index("oauth_auth_codes_used_idx").on(table.usedAt),
  }),
)

export const oauthAccessTokens = pgTable(
  "oauth_access_tokens",
  {
    tokenHash: varchar("token_hash", { length: 64 }).primaryKey(),
    grantId: varchar("grant_id", { length: 128 })
      .notNull()
      .references(() => oauthGrants.id),
    date: creationDate,
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    revokedAt: timestamp("revoked_at", { mode: "date", precision: 3 }),
  },
  (table) => ({
    oauthAccessTokensGrantIdx: index("oauth_access_tokens_grant_idx").on(table.grantId),
    oauthAccessTokensExpiryIdx: index("oauth_access_tokens_expiry_idx").on(table.expiresAt),
  }),
)

export const oauthRefreshTokens = pgTable(
  "oauth_refresh_tokens",
  {
    tokenHash: varchar("token_hash", { length: 64 }).primaryKey(),
    grantId: varchar("grant_id", { length: 128 })
      .notNull()
      .references(() => oauthGrants.id),
    replacedByHash: varchar("replaced_by_hash", { length: 64 }),
    date: creationDate,
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    revokedAt: timestamp("revoked_at", { mode: "date", precision: 3 }),
  },
  (table) => ({
    oauthRefreshTokensGrantIdx: index("oauth_refresh_tokens_grant_idx").on(table.grantId),
    oauthRefreshTokensExpiryIdx: index("oauth_refresh_tokens_expiry_idx").on(table.expiresAt),
    oauthRefreshTokensRevokedIdx: index("oauth_refresh_tokens_revoked_idx").on(table.revokedAt),
  }),
)

export type DbOauthClient = typeof oauthClients.$inferSelect
export type DbOauthAuthRequest = typeof oauthAuthRequests.$inferSelect
export type DbOauthGrant = typeof oauthGrants.$inferSelect
export type DbOauthAuthCode = typeof oauthAuthCodes.$inferSelect
export type DbOauthAccessToken = typeof oauthAccessTokens.$inferSelect
export type DbOauthRefreshToken = typeof oauthRefreshTokens.$inferSelect
