ALTER TABLE "chats" ADD COLUMN "last_message_date" timestamp (3);--> statement-breakpoint
-- Backfill from each chat's current last message. Chats without one stay null
-- and order by their creation date.
UPDATE "chats" AS c
SET "last_message_date" = m."date"
FROM "messages" AS m
WHERE m."chat_id" = c."id"
  AND m."message_id" = c."last_msg_id"
  AND c."last_msg_id" IS NOT NULL;
