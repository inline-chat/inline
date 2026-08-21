import { bytea, creationDate } from "@in/server/db/schema/common"
import { accountProvider } from "@in/server/db/schema/accountIdentities"
import { oauthAuthRequests } from "@in/server/db/schema/oauth"
import { loginTransactions } from "@in/server/db/schema/loginTransactions"
import { users } from "@in/server/db/schema/users"
import {
  foreignKey,
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"

export const providerAuthPurpose = pgEnum("provider_auth_purpose", ["app", "mcp_oauth", "hosted_login"])
export const providerAuthStatus = pgEnum("provider_auth_status", [
  "pending_provider",
  "pending_invite",
  "pending_email",
  "complete",
  "used",
])

export type ProviderAuthClient = {
  clientType: "ios" | "macos" | "web"
  deviceId?: string
  clientVersion?: string
  osVersion?: string
  deviceName?: string
  timezone?: string
}

export const providerAuthAttempts = pgTable(
  "provider_auth_attempts",
  {
    id: varchar({ length: 128 }).primaryKey(),
    provider: accountProvider().notNull(),
    purpose: providerAuthPurpose().notNull(),
    status: providerAuthStatus().default("pending_provider").notNull(),
    stateHash: varchar("state_hash", { length: 64 }).notNull(),
    nonceHash: varchar("nonce_hash", { length: 64 }).notNull(),
    nonceEncrypted: bytea("nonce_encrypted").notNull(),
    pkceVerifierEncrypted: bytea("pkce_verifier_encrypted"),
    continuationHash: varchar("continuation_hash", { length: 64 }),
    subjectHash: varchar("subject_hash", { length: 64 }),
    pendingProfileEncrypted: bytea("pending_profile_encrypted"),
    confirmationEmail: varchar("confirmation_email", { length: 256 }),
    challengeToken: varchar("challenge_token", { length: 128 }),
    appCallbackScheme: varchar("app_callback_scheme", { length: 64 }),
    appCodeChallenge: varchar("app_code_challenge", { length: 64 }),
    oauthAuthRequestId: varchar("oauth_auth_request_id", { length: 128 }),
    loginTransactionId: varchar("login_transaction_id", { length: 128 }),
    client: jsonb().$type<ProviderAuthClient>().notNull(),
    inlineUserId: integer("inline_user_id").references(() => users.id),
    inlineTokenEncrypted: bytea("inline_token_encrypted"),
    ticketHash: varchar("ticket_hash", { length: 64 }),
    date: creationDate,
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    usedAt: timestamp("used_at", { mode: "date", precision: 3 }),
  },
  (table) => ({
    providerAuthAttemptsOauthRequestFk: foreignKey({
      name: "provider_auth_attempts_oauth_request_fk",
      columns: [table.oauthAuthRequestId],
      foreignColumns: [oauthAuthRequests.id],
    }).onDelete("cascade"),
    providerAuthAttemptsStateUnique: uniqueIndex("provider_auth_attempts_state_unique").on(table.stateHash),
    providerAuthAttemptsTicketUnique: uniqueIndex("provider_auth_attempts_ticket_unique").on(table.ticketHash),
    providerAuthAttemptsExpiryIdx: index("provider_auth_attempts_expiry_idx").on(table.expiresAt),
    providerAuthAttemptsOauthRequestIdx: index("provider_auth_attempts_oauth_request_idx").on(
      table.oauthAuthRequestId,
    ),
    providerAuthAttemptsInlineUserIdx: index("provider_auth_attempts_inline_user_idx").on(table.inlineUserId),
    providerAuthAttemptsLoginTransactionFk: foreignKey({
      name: "provider_auth_attempts_login_transaction_fk",
      columns: [table.loginTransactionId],
      foreignColumns: [loginTransactions.id],
    }).onDelete("cascade"),
    providerAuthAttemptsLoginTransactionIdx: index("provider_auth_attempts_login_transaction_idx")
      .on(table.loginTransactionId),
  }),
)

export type ProviderAuthPurpose = (typeof providerAuthPurpose.enumValues)[number]
export type ProviderAuthStatus = (typeof providerAuthStatus.enumValues)[number]
export type DbProviderAuthAttempt = typeof providerAuthAttempts.$inferSelect
export type DbNewProviderAuthAttempt = typeof providerAuthAttempts.$inferInsert
