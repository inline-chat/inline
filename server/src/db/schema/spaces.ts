import { creationDate, date } from "@in/server/db/schema/common"
import { files } from "@in/server/db/schema/files"
import { members } from "@in/server/db/schema/members"
import { lower, users } from "@in/server/db/schema/users"
import { sql } from "drizzle-orm"
import { relations } from "drizzle-orm/_relations"
import { boolean, check, foreignKey, pgTable, varchar, serial, integer, timestamp, uniqueIndex } from "drizzle-orm/pg-core"

export const spaces = pgTable(
  "spaces",
  {
    id: serial().primaryKey(),
    name: varchar({ length: 256 }).notNull(),
    photoFileUniqueId: varchar("photo_file_unique_id", { length: 128 }),
    // Server-controlled entitlement; clients cannot set this through space profile APIs.
    isPro: boolean("is_pro").default(false).notNull(),
    handle: varchar({ length: 256 }),
    creatorId: integer().references(() => users.id),
    isPublic: boolean("is_public").default(false).notNull(),
    canPublicJoin: boolean("can_public_join").default(false).notNull(),
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
  (table) => [
    // Preserve the PostgreSQL-assigned name from committed migration 0150.
    foreignKey({
      name: "spaces_photo_file_unique_id_fkey",
      columns: [table.photoFileUniqueId],
      foreignColumns: [files.fileUniqueId],
    }).onDelete("set null"),
    uniqueIndex("spaces_handle_unique").on(lower(table.handle)),
    check(
      "spaces_public_join_handle_check",
      sql`not ${table.canPublicJoin} or (${table.isPublic} and ${table.handle} is not null and ${table.handle} ~ '^[A-Za-z0-9][A-Za-z0-9_-]{1,63}$')`,
    ),
  ],
)

export const spaceRelations = relations(spaces, ({ many }) => ({
  members: many(members),
}))

export type DbSpace = typeof spaces.$inferSelect
export type DbNewSpace = typeof spaces.$inferInsert
