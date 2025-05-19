import { pgTable, integer, text, timestamp, serial } from "drizzle-orm/pg-core"
import { users } from "./users"
import { relations } from "drizzle-orm/_relations"
import { bytea, creationDate } from "@in/server/db/schema/common"
import { spaces } from "./spaces"

export const integrations = pgTable("integrations", {
  id: serial("id").primaryKey(),

  userId: integer("user_id")
    .notNull()
    .references(() => users.id),
  spaceId: integer("space_id").references(() => spaces.id),

  provider: text("provider").notNull(),

  // Encrypted token data
  accessTokenEncrypted: bytea("access_token_encrypted"),
  accessTokenIv: bytea("access_token_iv"),
  accessTokenTag: bytea("access_token_tag"),

  date: creationDate,
})

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
