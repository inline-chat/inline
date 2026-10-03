import { users } from "./users"
import { pgTable, integer, text, timestamp, type AnyPgColumn } from "drizzle-orm/pg-core"

export const chatIdReservations = pgTable("chat_id_reservation", {
  chatId: integer("chat_id").primaryKey(),
  userId: integer("user_id")
    .notNull()
    .references((): AnyPgColumn => users.id),
  claimedAt: timestamp("claimed_at", {
    mode: "date",
    precision: 3,
  }),
  // Retained after claim so a lost create reply can reconcile the same intent.
  creationIntentHash: text("creation_intent_hash"),
  // A reserved reply may resolve to an existing anchored child. Retain this
  // identity after that child is deleted rather than allowing a replacement.
  resolvedChatId: integer("resolved_chat_id"),
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
