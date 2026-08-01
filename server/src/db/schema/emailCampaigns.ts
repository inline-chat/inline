import { sql } from "drizzle-orm"
import {
  boolean,
  check,
  index,
  integer,
  jsonb,
  pgTable,
  serial,
  text,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"
import { bytea } from "./common"
import { users } from "./users"

export const emailCampaigns = pgTable(
  "email_campaigns",
  {
    id: serial("id").primaryKey(),
    name: varchar("name", { length: 160 }).notNull(),
    seriesKey: varchar("series_key", { length: 160 }),
    subject: varchar("subject", { length: 240 }).notNull(),
    previewText: varchar("preview_text", { length: 240 }),
    bodyText: text("body_text").notNull(),
    audience: jsonb("audience").notNull(),
    provider: varchar("provider", { length: 16 }),
    fromAddress: varchar("from_address", { length: 160 }).default("team@inline.chat").notNull(),
    status: varchar("status", { length: 32 }).default("frozen").notNull(),
    recipientCount: integer("recipient_count").default(0).notNull(),
    providerSegmentId: varchar("provider_segment_id", { length: 256 }),
    providerCampaignId: varchar("provider_campaign_id", { length: 256 }),
    createdByUserId: integer("created_by_user_id")
      .notNull()
      .references(() => users.id),
    visibleUnsubscribe: boolean("visible_unsubscribe").default(true).notNull(),
    unsubscribeOverrideReason: text("unsubscribe_override_reason"),
    testSentAt: timestamp("test_sent_at", { mode: "date", withTimezone: true }),
    createdAt: timestamp("created_at", { mode: "date", withTimezone: true }).defaultNow().notNull(),
    frozenAt: timestamp("frozen_at", { mode: "date", withTimezone: true }).defaultNow().notNull(),
    completedAt: timestamp("completed_at", { mode: "date", withTimezone: true }),
  },
  (table) => [
    uniqueIndex("email_campaigns_name_unique").on(table.name),
    index("email_campaigns_created_at_idx").on(table.createdAt),
    check(
      "email_campaigns_provider_check",
      sql`${table.provider} is null or ${table.provider} in ('resend', 'ses')`,
    ),
    check(
      "email_campaigns_from_address_check",
      sql`${table.fromAddress} in ('team@inline.chat', 'founders@inline.chat', 'mo@inline.chat')`,
    ),
    check(
      "email_campaigns_status_check",
      sql`${table.status} in ('frozen', 'sending', 'paused', 'completed')`,
    ),
  ],
)

export const emailCampaignRecipients = pgTable(
  "email_campaign_recipients",
  {
    id: serial("id").primaryKey(),
    campaignId: integer("campaign_id")
      .notNull()
      .references(() => emailCampaigns.id, { onDelete: "cascade" }),
    emailKey: varchar("email_key", { length: 64 }).notNull(),
    emailEncrypted: bytea("email_encrypted").notNull(),
    nameEncrypted: bytea("name_encrypted"),
    unsubscribeTokenHash: varchar("unsubscribe_token_hash", { length: 64 }).notNull(),
    unsubscribeTokenEncrypted: bytea("unsubscribe_token_encrypted").notNull(),
    sources: jsonb("sources").notNull(),
    status: varchar("status", { length: 32 }).default("pending").notNull(),
    attemptCount: integer("attempt_count").default(0).notNull(),
    provider: varchar("provider", { length: 32 }),
    providerMessageId: varchar("provider_message_id", { length: 256 }),
    lastAttemptAt: timestamp("last_attempt_at", { mode: "date", withTimezone: true }),
    contactedAt: timestamp("contacted_at", { mode: "date", withTimezone: true }),
    createdAt: timestamp("created_at", { mode: "date", withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    uniqueIndex("email_campaign_recipients_campaign_email_unique").on(
      table.campaignId,
      table.emailKey,
    ),
    uniqueIndex("email_campaign_recipients_unsubscribe_token_unique").on(
      table.unsubscribeTokenHash,
    ),
    index("email_campaign_recipients_campaign_status_idx").on(
      table.campaignId,
      table.status,
      table.id,
    ),
    index("email_campaign_recipients_email_key_idx").on(table.emailKey),
    check(
      "email_campaign_recipients_status_check",
      sql`${table.status} in ('pending', 'provider_synced', 'sending', 'provider_accepted', 'unknown', 'suppressed')`,
    ),
  ],
)

export const emailSuppressions = pgTable(
  "email_suppressions",
  {
    id: serial("id").primaryKey(),
    emailKey: varchar("email_key", { length: 64 }).notNull(),
    emailEncrypted: bytea("email_encrypted").notNull(),
    reason: varchar("reason", { length: 32 }).notNull(),
    createdAt: timestamp("created_at", { mode: "date", withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    uniqueIndex("email_suppressions_email_key_unique").on(table.emailKey),
    check(
      "email_suppressions_reason_check",
      sql`${table.reason} in ('unsubscribe', 'manual', 'bounce', 'complaint', 'invalid')`,
    ),
  ],
)

export type DbEmailCampaign = typeof emailCampaigns.$inferSelect
export type DbEmailCampaignRecipient = typeof emailCampaignRecipients.$inferSelect
