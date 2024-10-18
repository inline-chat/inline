import { creationDate } from "@in/server/db/schema/common"
import { bigserial } from "drizzle-orm/pg-core"
import {
  pgTable,
  varchar,
  boolean,
  timestamp,
  serial,
  bigint,
} from "drizzle-orm/pg-core"

export const spaces = pgTable("spaces", {
  id: serial().primaryKey(),
  name: varchar({ length: 256 }).notNull(),
  handle: varchar({ length: 32 }).unique(),
  date: creationDate,
})

export type DbSpace = typeof spaces.$inferSelect
export type DbNewSpace = typeof spaces.$inferInsert
