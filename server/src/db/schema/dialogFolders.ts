import { creationDate } from "@in/server/db/schema/common"
import { users } from "@in/server/db/schema/users"
import { index, integer, pgTable, serial, text, unique } from "drizzle-orm/pg-core"

export const dialogFolders = pgTable(
  "dialog_folders",
  {
    id: serial().primaryKey(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id),
    title: text("title"),
    emoji: text("emoji"),
    order: text("order").notNull(),
    pinnedOrder: text("pinned_order"),
    date: creationDate,
  },
  (table) => ({
    idUserIdUnique: unique("dialog_folders_id_user_id_unique").on(table.id, table.userId),
    userIdOrderIndex: index("dialog_folders_user_id_order_idx").on(table.userId, table.order),
    userIdPinnedOrderIndex: index("dialog_folders_user_id_pinned_order_idx").on(table.userId, table.pinnedOrder),
  }),
)

export type DbDialogFolder = typeof dialogFolders.$inferSelect
export type DbNewDialogFolder = typeof dialogFolders.$inferInsert
