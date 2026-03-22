import { users } from "./users"
import { pgTable, integer, timestamp, type AnyPgColumn } from "drizzle-orm/pg-core"

export const chatIdReservations = pgTable("chat_id_reservation", {
  chatId: integer("chat_id").primaryKey(),
  userId: integer("user_id")
    .notNull()
    .references((): AnyPgColumn => users.id),
  claimedAt: timestamp("claimed_at", {
    mode: "date",
    precision: 3,
  }),
  expiresAt: timestamp("expires_at", {
    mode: "date",
    precision: 3,
  }).notNull(),
  createdAt: timestamp("created_at", {
    mode: "date",
    precision: 3,
  })
    .defaultNow()
    .notNull(),
})

export type DbChatIdReservation = typeof chatIdReservations.$inferSelect
export type DbNewChatIdReservation = typeof chatIdReservations.$inferInsert
