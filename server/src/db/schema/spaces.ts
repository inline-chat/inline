import {
  pgTable,
  varchar,
  boolean,
  timestamp,
  bigint,
} from "drizzle-orm/pg-core"

export const spaces = pgTable("spaces", {
  id: bigint("id", { mode: "bigint" }),
  name: varchar("name", { length: 256 }),
  handle: varchar("handle", { length: 32 }).unique(),
  deleted: boolean("deleted"),
  date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
})

export type DbSpace = typeof spaces.$inferSelect
export type DbNewSpace = typeof spaces.$inferInsert
