import {
  pgTable,
  varchar,
  boolean,
  timestamp,
  bigint,
  pgEnum,
  unique,
} from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { bigserial } from "drizzle-orm/pg-core"

export const rolesEnum = pgEnum("member_roles", ["owner", "admin", "member"])

export const members = pgTable(
  "members",
  {
    id: bigserial({ mode: "bigint" }).primaryKey(),
    userId: bigint("user_id", { mode: "bigint" })
      .notNull()
      .references(() => users.id, {
        onDelete: "cascade",
      }),
    spaceId: bigint("space_id", { mode: "bigint" })
      .notNull()
      .references(() => spaces.id, {
        onDelete: "cascade",
      }),
    role: rolesEnum().default("member"),
    date: timestamp({ mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({ uniqueUserInSpace: unique().on(table.userId, table.spaceId) }),
)

export type DbMember = typeof members.$inferSelect
export type DbNewMember = typeof members.$inferInsert
