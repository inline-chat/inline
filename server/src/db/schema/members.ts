import { pgTable, pgEnum, unique, integer, timestamp, boolean } from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { creationDate } from "@in/server/db/schema/common"
import { serial } from "drizzle-orm/pg-core"
import { relations } from "drizzle-orm"

export const rolesEnum = pgEnum("member_roles", ["owner", "admin", "member"])

export const members = pgTable(
  "members",
  {
    id: serial().primaryKey(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, {
        onDelete: "cascade",
      }),
    spaceId: integer("space_id")
      .notNull()
      .references(() => spaces.id, {
        onDelete: "cascade",
      }),
    role: rolesEnum().default("member"),

    // per member state
    // pinned: boolean("pinned").default(false),
    // archivedAt: timestamp("archived_at"),
    // lastInteractionDate: timestamp("last_interaction_date"),

    date: creationDate,
  },
  (table) => ({ uniqueUserInSpace: unique().on(table.userId, table.spaceId) }),
)

export const membersRelations = relations(members, ({ one }) => ({
  user: one(users, {
    fields: [members.userId],
    references: [users.id],
  }),
  space: one(spaces, {
    fields: [members.spaceId],
    references: [spaces.id],
  }),
}))

export type DbMember = typeof members.$inferSelect
export type DbNewMember = typeof members.$inferInsert
