import { SQL, sql } from "drizzle-orm"
import { integer, pgTable, uniqueIndex, varchar, boolean, timestamp, type AnyPgColumn } from "drizzle-orm/pg-core"
import { pgSequence } from "drizzle-orm/pg-core"
import { files, type DbFile } from "./files"
import { relations } from "drizzle-orm"

// custom lower function
export function lower(email: AnyPgColumn): SQL {
  return sql`lower(${email})`
}

// Sequence with params
export const userIdSequence = pgSequence("user_id", {
  startWith: 1000,
  minValue: 1000,
  cycle: false,
  cache: 100,
  increment: 3,
})

export const users = pgTable(
  "users",
  {
    id: integer("id")
      .default(sql`nextval('user_id')`)
      .primaryKey(),
    email: varchar("email", { length: 256 }).unique(),
    phoneNumber: varchar("phone_number", { length: 15 }).unique(),
    emailVerified: boolean("email_verified"),
    phoneVerified: boolean("phone_verified"),
    firstName: varchar("first_name", { length: 256 }),
    lastName: varchar("last_name", { length: 256 }),
    username: varchar("username", { length: 256 }),
    deleted: boolean("deleted"),
    online: boolean("online").default(false).notNull(),
    lastOnline: timestamp("last_online", { mode: "date", precision: 3 }),
    date: timestamp("date", { mode: "date", precision: 3 }).defaultNow(),
    photoFileId: integer("photo_file_id").references((): AnyPgColumn => files.id),
    pendingSetup: boolean("pending_setup").default(false),
    timeZone: varchar("time_zone", { length: 256 }),
  },
  (table) => ({
    users_username_unique: uniqueIndex("users_username_unique").on(lower(table.username)),
  }),
)

// Add relationships
export const usersRelations = relations(users, ({ one }) => ({
  photo: one(files, {
    fields: [users.photoFileId],
    references: [files.id],
  }),
}))

export type DbUser = typeof users.$inferSelect
export type DbUserWithPhoto = DbUser & { photo?: (DbFile & { thumbs?: DbFile[] | null }) | null }
export type DbNewUser = typeof users.$inferInsert
