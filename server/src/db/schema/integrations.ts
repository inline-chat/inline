import { pgTable, integer, text, serial, uniqueIndex, varchar, timestamp, index } from "drizzle-orm/pg-core"
import { users } from "./users"
import { relations } from "drizzle-orm/_relations"
import { bytea, creationDate } from "@in/server/db/schema/common"
import { spaces } from "./spaces"

export const integrations = pgTable(
  "integrations",
  {
    id: serial("id").primaryKey(),

    userId: integer("user_id").references(() => users.id),

    spaceId: integer("space_id").references(() => spaces.id),

    provider: text("provider").notNull(),

    // Encrypted token data
    accessTokenEncrypted: bytea("access_token_encrypted"),
    accessTokenIv: bytea("access_token_iv"),
    accessTokenTag: bytea("access_token_tag"),

    // Notion related data
    notionDatabaseId: text("notion_database_id"),

    // Linear related data (space-level selection)
    linearTeamId: text("linear_team_id"),

    date: timestamp("date", {
      mode: "date",
      precision: 3,
      withTimezone: true,
    })
      .defaultNow()
      .notNull(),
  },
  (table) => ({
    integrations_space_provider_unique: uniqueIndex("integrations_space_provider_unique").on(
      table.spaceId,
      table.provider,
    ),
  }),
)

export const integrationRelations = relations(integrations, ({ one }) => ({
  user: one(users, {
    fields: [integrations.userId],
    references: [users.id],
  }),
  space: one(spaces, {
    fields: [integrations.spaceId],
    references: [spaces.id],
  }),
}))

export type DbIntegration = typeof integrations.$inferSelect
export type NewIntegration = typeof integrations.$inferInsert

/**
 * Single-use OAuth state. Only a SHA-256 digest is persisted; the raw state is
 * returned to the provider and cannot be recovered from the database.
 */
export const integrationOAuthStates = pgTable(
  "integration_oauth_states",
  {
    stateHash: varchar("state_hash", { length: 64 }).primaryKey(),
    provider: varchar("provider", { length: 32 }).notNull(),
    callbackScheme: varchar("callback_scheme", { length: 32 }).notNull(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    spaceId: integer("space_id").references(() => spaces.id, { onDelete: "cascade" }),
    expiresAt: timestamp("expires_at", { mode: "date", precision: 3 }).notNull(),
    date: creationDate,
  },
  (table) => ({
    integration_oauth_states_user: index("integration_oauth_states_user").on(table.userId),
    integration_oauth_states_expires: index("integration_oauth_states_expires").on(table.expiresAt),
  }),
)

export type DbIntegrationOAuthState = typeof integrationOAuthStates.$inferSelect
