import { chats } from "@in/server/db/schema/chats"
import { creationDate } from "@in/server/db/schema/common"
import { spaces } from "@in/server/db/schema/spaces"
import { users } from "@in/server/db/schema/users"
import { pgTable, integer, bytea, varchar, index, unique, bigint } from "drizzle-orm/pg-core"

// enum for bucket
export enum UpdateBucket {
  Chat = 1,
  User = 2,
  Space = 3,
}

export const updates = pgTable(
  "updates",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
    date: creationDate,

    // type of message box it belongs to
    bucket: integer("bucket").notNull(),
    entityId: integer("entity_id").notNull(),

    // PTS
    seq: integer("seq").notNull(),

    // Encrypted update text
    payload: bytea("payload").notNull(),
  },
  (t) => [
    index("updates_bucket_idx").on(t.bucket, t.entityId, t.seq),
    index("updates_date_idx").on(t.date),
    unique("updates_unique").on(t.bucket, t.entityId, t.seq),
  ],
)

export type DbUpdate = typeof updates.$inferSelect
export type DbNewUpdate = typeof updates.$inferInsert
