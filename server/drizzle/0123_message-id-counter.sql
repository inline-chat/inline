ALTER TABLE "chats" ADD COLUMN "message_id_counter" integer DEFAULT 0 NOT NULL;
UPDATE "chats" AS c
SET "message_id_counter" = COALESCE(
  (SELECT MAX(m."message_id") FROM "messages" AS m WHERE m."chat_id" = c."id"),
  0
);
