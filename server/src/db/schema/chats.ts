import {
  pgTable,
  varchar,
  boolean,
  timestamp,
  bigint,
  pgEnum,
  makePgArray,
  unique,
  check,
} from "drizzle-orm/pg-core"
import { users } from "./users"
import { spaces } from "./spaces"
import { sql } from "drizzle-orm"
import { bigserial } from "drizzle-orm/pg-core"

export const chatTypeEnum = pgEnum("chat_types", ["private", "thread"])

export const chats = pgTable(
  "chats",
  {
    id: bigserial({ mode: "bigint" }).primaryKey(),
    type: chatTypeEnum().notNull(),
    title: varchar(),

    /** optional, if part of a space */
    spaceId: bigint("space_id", { mode: "bigint" }).references(() => spaces.id),

    /** optional, required for private chats, least user id */
    minUserId: bigint("min_user_id", { mode: "bigint" }).references(
      () => users.id,
    ),
    /** optional, required for private chats, greatest user id */
    maxUserId: bigint("max_user_id", { mode: "bigint" }).references(
      () => users.id,
    ),

    date: timestamp({ mode: "date", precision: 3 }).defaultNow(),
  },
  (table) => ({
    /** Ensure correctness */
    userIdsCheckConstraint: check(
      "user_ids_check",
      sql`${table.minUserId} < ${table.maxUserId}`,
    ),
    /** Ensure single private chat exists for each user pair */
    userIdsUniqueContraint: unique("user_ids_unique").on(
      table.minUserId,
      table.maxUserId,
    ),
  }),
)

export type DbChat = typeof chats.$inferSelect
export type DbNewChat = typeof chats.$inferInsert
