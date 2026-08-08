ALTER TABLE "chats" ADD COLUMN "message_id_high_water" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
UPDATE "chats"
SET "message_id_high_water" = GREATEST(
  COALESCE("last_msg_id", 0),
  COALESCE((
    SELECT MAX("messages"."message_id")
    FROM "messages"
    WHERE "messages"."chat_id" = "chats"."id"
  ), 0)
);--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "collapsed_max_id" integer;--> statement-breakpoint
ALTER TABLE "dialogs" ADD CONSTRAINT "dialogs_collapsed_max_id_positive" CHECK ("dialogs"."collapsed_max_id" > 0);
