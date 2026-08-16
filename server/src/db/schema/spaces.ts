import { creationDate, date } from "@in/server/db/schema/common"
import { members } from "@in/server/db/schema/members"
import { lower, users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"
import { boolean, pgTable, varchar, serial, integer, timestamp, uniqueIndex } from "drizzle-orm/pg-core"

export const spaces = pgTable(
  "spaces",
  {
    id: serial().primaryKey(),
    name: varchar({ length: 256 }).notNull(),
    handle: varchar({ length: 256 }),
    creatorId: integer().references(() => users.id),
    isPublic: boolean("is_public").default(false).notNull(),
    date: creationDate,
    deleted: date,

    /** Next monotonic thread number available in this space's scope. */
    nextThreadNumber: integer("next_thread_number").default(1).notNull(),

    /** Sequence of the updates for the space */
    updateSeq: integer("update_seq").default(0),

    /** Date of the last update */
    lastUpdateDate: timestamp("last_update_date", {
      mode: "date",
      precision: 3,
    }),

    /** Monotonic version of this Space's replaceable Grid snapshot. */
    gridRevision: integer("grid_revision").default(0).notNull(),
  },
  (table) => ({
    spacesHandleUnique: uniqueIndex("spaces_handle_unique").on(lower(table.handle)),
  }),
)

export const spaceRelations = relations(spaces, ({ many }) => ({
  members: many(members),
}))

export type DbSpace = typeof spaces.$inferSelect
export type DbNewSpace = typeof spaces.$inferInsert
