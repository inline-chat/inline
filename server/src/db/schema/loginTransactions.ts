import { sql } from "drizzle-orm"
import type { SignupAttribution } from "@in/server/modules/auth/signupAttribution"
import {
  check,
  index,
  integer,
  jsonb,
  pgTable,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"
import { bytea } from "./common"
import { inlineProtocolAuthKeys } from "./inlineProtocol"
import { oauthAuthRequests } from "./oauth"
import { users } from "./users"

export type HostedAuthClient = {
  signupAttribution?: SignupAttribution
  clientType?: string
  deviceId?: string
  clientVersion?: string
  osVersion?: string
  deviceName?: string
}

export const nativeAppAuthRequests = pgTable(
  "native_app_auth_requests",
  {
    id: varchar({ length: 128 }).primaryKey(),
    callbackScheme: varchar("callback_scheme", { length: 64 }).notNull(),
    codeChallenge: varchar("code_challenge", { length: 64 }).notNull(),
    client: jsonb().$type<HostedAuthClient>().notNull(),
    userId: integer("user_id").references(() => users.id),
    authMethod: varchar("auth_method", { length: 16 }),
    ticketHash: bytea("ticket_hash"),
    createdAt: timestamp("created_at", { mode: "date", precision: 3, withTimezone: true }).defaultNow().notNull(),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3, withTimezone: true }).notNull(),
    provenAt: timestamp("proven_at", { mode: "date", precision: 3, withTimezone: true }),
    redeemedAt: timestamp("redeemed_at", { mode: "date", precision: 3, withTimezone: true }),
    cancelledAt: timestamp("cancelled_at", { mode: "date", precision: 3, withTimezone: true }),
  },
  (table) => ({
    expiryIndex: index("native_app_auth_requests_expiry_idx").on(table.expiresAt),
    ticketUnique: uniqueIndex("native_app_auth_requests_ticket_unique").on(table.ticketHash),
    methodValid: check(
      "native_app_auth_requests_method_valid",
      sql`${table.authMethod} is null or ${table.authMethod} in ('email', 'phone', 'google', 'apple')`,
    ),
  }),
)

export const loginTransactions = pgTable(
  "login_transactions",
  {
    id: varchar({ length: 128 }).primaryKey(),
    capabilityHash: bytea("capability_hash").notNull(),
    browserCsrfHash: bytea("browser_csrf_hash"),
    status: varchar({ length: 16 }).default("pending").notNull(),
    targetKind: varchar("target_kind", { length: 32 }).notNull(),
    inlineProtocolAuthKeyId: bytea("inline_protocol_auth_key_id")
      .references(() => inlineProtocolAuthKeys.authKeyId, { onDelete: "cascade" }),
    oauthAuthRequestId: varchar("oauth_auth_request_id", { length: 128 })
      .references(() => oauthAuthRequests.id, { onDelete: "cascade" }),
    nativeAppAuthRequestId: varchar("native_app_auth_request_id", { length: 128 })
      .references(() => nativeAppAuthRequests.id, { onDelete: "cascade" }),
    verificationCode: varchar("verification_code", { length: 12 }).notNull(),
    pendingIdentifier: varchar("pending_identifier", { length: 320 }),
    challengeToken: varchar("challenge_token", { length: 128 }),
    client: jsonb().$type<HostedAuthClient>().notNull(),
    userId: integer("user_id").references(() => users.id),
    authMethod: varchar("auth_method", { length: 16 }),
    createdAt: timestamp("created_at", { mode: "date", precision: 3, withTimezone: true }).defaultNow().notNull(),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3, withTimezone: true }).notNull(),
    claimedAt: timestamp("claimed_at", { mode: "date", precision: 3, withTimezone: true }),
    completedAt: timestamp("completed_at", { mode: "date", precision: 3, withTimezone: true }),
    cancelledAt: timestamp("cancelled_at", { mode: "date", precision: 3, withTimezone: true }),
  },
  (table) => ({
    capabilityUnique: uniqueIndex("login_transactions_capability_unique").on(table.capabilityHash),
    expiryIndex: index("login_transactions_expiry_idx").on(table.expiresAt),
    userIndex: index("login_transactions_user_idx").on(table.userId),
    inlineProtocolKeyUnique: uniqueIndex("login_transactions_inline_protocol_key_unique")
      .on(table.inlineProtocolAuthKeyId)
      .where(sql`${table.status} in ('pending', 'claimed')`),
    oauthRequestUnique: uniqueIndex("login_transactions_oauth_request_unique")
      .on(table.oauthAuthRequestId)
      .where(sql`${table.status} in ('pending', 'claimed')`),
    nativeAppRequestUnique: uniqueIndex("login_transactions_native_app_request_unique")
      .on(table.nativeAppAuthRequestId)
      .where(sql`${table.status} in ('pending', 'claimed')`),
    capabilityLength: check(
      "login_transactions_capability_hash_length",
      sql`octet_length(${table.capabilityHash}) = 32`,
    ),
    csrfLength: check(
      "login_transactions_browser_csrf_hash_length",
      sql`${table.browserCsrfHash} is null or octet_length(${table.browserCsrfHash}) = 32`,
    ),
    statusValid: check(
      "login_transactions_status_valid",
      sql`${table.status} in ('pending', 'claimed', 'complete', 'cancelled')`,
    ),
    methodValid: check(
      "login_transactions_method_valid",
      sql`${table.authMethod} is null or ${table.authMethod} in ('email', 'phone', 'google', 'apple')`,
    ),
    typedTarget: check(
      "login_transactions_typed_target",
      sql`(
        (${table.targetKind} = 'inline_protocol_key')::int +
        (${table.targetKind} = 'oauth_authorization')::int +
        (${table.targetKind} = 'native_app')::int
      ) = 1 and
      (${table.inlineProtocolAuthKeyId} is not null)::int +
      (${table.oauthAuthRequestId} is not null)::int +
      (${table.nativeAppAuthRequestId} is not null)::int = 1 and
      (${table.targetKind} = 'inline_protocol_key') = (${table.inlineProtocolAuthKeyId} is not null) and
      (${table.targetKind} = 'oauth_authorization') = (${table.oauthAuthRequestId} is not null) and
      (${table.targetKind} = 'native_app') = (${table.nativeAppAuthRequestId} is not null)
      `,
    ),
  }),
)

export type DbLoginTransaction = typeof loginTransactions.$inferSelect
export type DbNewLoginTransaction = typeof loginTransactions.$inferInsert
export type DbNativeAppAuthRequest = typeof nativeAppAuthRequests.$inferSelect
