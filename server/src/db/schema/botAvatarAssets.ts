import { integer, pgTable, serial, text, timestamp, varchar } from "drizzle-orm/pg-core"
import { creationDate } from "@in/server/db/schema/common"
import { users } from "./users"
import { files } from "./files"

export const botAvatarAssets = pgTable("bot_avatar_assets", {
  id: serial("id").primaryKey(),
  botUserId: integer("bot_user_id")
    .notNull()
    .unique()
    .references(() => users.id),
  kind: text("kind", { enum: ["codex_atlas"] }).notNull(),
  displayName: varchar("display_name", { length: 256 }).notNull(),
  description: text("description"),
  fileId: integer("file_id")
    .notNull()
    .references(() => files.id),
  date: creationDate,
  updatedAt: timestamp("updated_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
})

export type DbBotAvatarAsset = typeof botAvatarAssets.$inferSelect
export type DbNewBotAvatarAsset = typeof botAvatarAssets.$inferInsert
