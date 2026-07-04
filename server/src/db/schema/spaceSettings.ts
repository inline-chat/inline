import { spaces } from "@in/server/db/schema/spaces"
import { bytea, integer, pgTable, timestamp } from "drizzle-orm/pg-core"

export const spaceSettings = pgTable("space_settings", {
  spaceId: integer("space_id")
    .primaryKey()
    .references(() => spaces.id, { onDelete: "cascade" }),
  payload: bytea("payload").notNull(),
  updatedAt: timestamp("updated_at", {
    mode: "date",
    precision: 3,
  })
    .defaultNow()
    .notNull(),
})

export type DbSpaceSettings = typeof spaceSettings.$inferSelect
export type DbNewSpaceSettings = typeof spaceSettings.$inferInsert
