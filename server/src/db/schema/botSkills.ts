import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"
import { integer, pgTable, serial, text, timestamp, uniqueIndex, varchar } from "drizzle-orm/pg-core"

export const botSkills = pgTable(
  "bot_skills",
  {
    id: serial("id").primaryKey(),
    botUserId: integer("bot_user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    key: varchar("key", { length: 256 }).notNull(),
    name: varchar("name", { length: 256 }).notNull(),
    description: text("description"),
    sortOrder: integer("sort_order").notNull().default(0),
    createdAt: timestamp("created_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
  },
  (table) => ({
    botSkillsBotUserIdKeyUnique: uniqueIndex("bot_skills_bot_user_id_key_unique").on(
      table.botUserId,
      table.key,
    ),
  }),
)

export const botSkillsRelations = relations(botSkills, ({ one }) => ({
  botUser: one(users, {
    fields: [botSkills.botUserId],
    references: [users.id],
  }),
}))

export type DbBotSkill = typeof botSkills.$inferSelect
export type DbNewBotSkill = typeof botSkills.$inferInsert
