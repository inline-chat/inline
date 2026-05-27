import { integer, index, pgTable, serial, timestamp, uniqueIndex, varchar } from "drizzle-orm/pg-core"
import { users } from "./users"
import { creationDate } from "./common"

export const inviteCodes = pgTable(
  "invite_codes",
  {
    id: serial("id").primaryKey(),
    code: varchar("code", { length: 8 }).notNull(),
    ownerUserId: integer("owner_user_id").references(() => users.id, {
      onDelete: "set null",
    }),
    createdByUserId: integer("created_by_user_id").references(() => users.id, {
      onDelete: "set null",
    }),
    redeemedByUserId: integer("redeemed_by_user_id").references(() => users.id, {
      onDelete: "set null",
    }),
    note: varchar("note", { length: 256 }),
    date: creationDate,
    redeemedAt: timestamp("redeemed_at", { mode: "date", precision: 3 }),
  },
  (table) => ({
    codeUnique: uniqueIndex("invite_codes_code_unique").on(table.code),
    ownerUserIdIndex: index("invite_codes_owner_user_id_idx").on(table.ownerUserId),
    redeemedByUserIdIndex: index("invite_codes_redeemed_by_user_id_idx").on(table.redeemedByUserId),
  }),
)

export type DbInviteCode = typeof inviteCodes.$inferSelect
export type DbNewInviteCode = typeof inviteCodes.$inferInsert
