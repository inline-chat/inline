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

export const rolesEnum = pgEnum("member_roles", ["owner", "admin", "member"])

export const members = pgTable(
  "members",
  {
    id: bigint("id", { mode: "bigint" }),
    userId: bigint("user_id", { mode: "bigint" })
      .notNull()
      .references(() => users.id),
    spaceId: bigint("space_id", { mode: "bigint" })
      .notNull()
      .references(() => spaces.id),
    role: rolesEnum("role").default("member"),
    deleted: boolean("deleted"),
    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({ uniqueUserInSpace: unique().on(table.userId, table.spaceId) }),
)

export type DbMember = typeof members.$inferSelect
export type DbNewMember = typeof members.$inferInsert
