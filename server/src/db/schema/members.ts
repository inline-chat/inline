import {
  pgTable,
  varchar,
  boolean,
  timestamp,
  bigint,
  pgEnum,
  unique,
  integer,
} from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { bigserial } from "drizzle-orm/pg-core"
import { creationDate } from "@in/server/db/schema/common"
import { serial } from "drizzle-orm/pg-core"

export const rolesEnum = pgEnum("member_roles", ["owner", "admin", "member"])

export const members = pgTable(
  "members",
  {
    id: serial().primaryKey(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, {
        onDelete: "cascade",
      }),
    spaceId: integer("space_id")
      .notNull()
      .references(() => spaces.id, {
        onDelete: "cascade",
      }),
    role: rolesEnum().default("member"),
    date: creationDate,
  },
  (table) => ({ uniqueUserInSpace: unique().on(table.userId, table.spaceId) }),
)

export type DbMember = typeof members.$inferSelect
export type DbNewMember = typeof members.$inferInsert
