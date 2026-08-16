import { creationDate } from "@in/server/db/schema/common"
import { users } from "@in/server/db/schema/users"
import {
  index,
  integer,
  pgEnum,
  pgTable,
  serial,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"

export const accountProvider = pgEnum("account_provider", ["google", "apple"])

export const accountIdentities = pgTable(
  "account_identities",
  {
    id: serial().primaryKey(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id),
    provider: accountProvider().notNull(),
    subjectHash: varchar("subject_hash", { length: 64 }).notNull(),
    date: creationDate,
  },
  (table) => ({
    accountIdentitiesProviderSubjectUnique: uniqueIndex(
      "account_identities_provider_subject_unique",
    ).on(table.provider, table.subjectHash),
    accountIdentitiesUserIdx: index("account_identities_user_idx").on(table.userId),
  }),
)

export type AccountProvider = (typeof accountProvider.enumValues)[number]
export type DbAccountIdentity = typeof accountIdentities.$inferSelect
export type DbNewAccountIdentity = typeof accountIdentities.$inferInsert
