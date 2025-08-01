import { creationDate, date } from "@in/server/db/schema/common"
import { members } from "@in/server/db/schema/members"
import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"
import { pgTable, varchar, serial, integer, timestamp } from "drizzle-orm/pg-core"

export const spaces = pgTable("spaces", {
  id: serial().primaryKey(),
  name: varchar({ length: 256 }).notNull(),
  handle: varchar({ length: 32 }).unique(),
  creatorId: integer().references(() => users.id),
  date: creationDate,
  deleted: date,

  /** Sequence of the updates for the space */
  updateSeq: integer("update_seq").default(0),

  /** Date of the last update */
  lastUpdateDate: timestamp("last_update_date", {
    mode: "date",
    precision: 3,
  }),
})

export const spaceRelations = relations(spaces, ({ many }) => ({
  members: many(members),
}))

export type DbSpace = typeof spaces.$inferSelect
export type DbNewSpace = typeof spaces.$inferInsert
