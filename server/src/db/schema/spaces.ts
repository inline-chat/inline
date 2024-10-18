import { bigserial } from "drizzle-orm/pg-core"
import {
  pgTable,
  varchar,
  boolean,
  timestamp,
  bigint,
} from "drizzle-orm/pg-core"

export const spaces = pgTable("spaces", {
  id: bigserial({ mode: "bigint" }).primaryKey(),
  name: varchar({ length: 256 }).notNull(),
  handle: varchar({ length: 32 }).unique(),
  date: timestamp({ mode: "date", precision: 3 }).defaultNow(),
})

export type DbSpace = typeof spaces.$inferSelect
export type DbNewSpace = typeof spaces.$inferInsert
