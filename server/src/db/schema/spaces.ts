import { creationDate } from "@in/server/db/schema/common"
import { members } from "@in/server/db/schema/members"
import { relations } from "drizzle-orm"
import { pgTable, varchar, serial } from "drizzle-orm/pg-core"

export const spaces = pgTable("spaces", {
  id: serial().primaryKey(),
  name: varchar({ length: 256 }).notNull(),
  handle: varchar({ length: 32 }).unique(),
  date: creationDate,
})

export const spaceRelations = relations(spaces, ({ many }) => ({
  members: many(members),
}))

export type DbSpace = typeof spaces.$inferSelect
export type DbNewSpace = typeof spaces.$inferInsert
