import { creationDate } from "@in/server/db/schema/common"
import { spaces } from "@in/server/db/schema/spaces"
import { users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"
import { bigint, index, integer, pgTable, text, uniqueIndex } from "drizzle-orm/pg-core"

export const spaceUrlPreviewExclusions = pgTable(
  "space_url_preview_exclusions",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
    spaceId: integer("space_id")
      .notNull()
      .references(() => spaces.id, { onDelete: "cascade" }),
    host: text("host").notNull(),
    pathPrefix: text("path_prefix").notNull().default(""),
    createdBy: integer("created_by")
      .notNull()
      .references(() => users.id),
    date: creationDate,
  },
  (table) => ({
    spaceHostPathUnique: uniqueIndex("space_url_preview_exclusions_space_host_path_unique").on(
      table.spaceId,
      table.host,
      table.pathPrefix,
    ),
    spaceHostIndex: index("space_url_preview_exclusions_space_host_idx").on(table.spaceId, table.host),
    createdByIndex: index("space_url_preview_exclusions_created_by_idx").on(table.createdBy),
  }),
)

export const spaceUrlPreviewExclusionsRelations = relations(spaceUrlPreviewExclusions, ({ one }) => ({
  space: one(spaces, {
    fields: [spaceUrlPreviewExclusions.spaceId],
    references: [spaces.id],
  }),
  creator: one(users, {
    fields: [spaceUrlPreviewExclusions.createdBy],
    references: [users.id],
  }),
}))

export type DbSpaceUrlPreviewExclusion = typeof spaceUrlPreviewExclusions.$inferSelect
export type DbNewSpaceUrlPreviewExclusion = typeof spaceUrlPreviewExclusions.$inferInsert
