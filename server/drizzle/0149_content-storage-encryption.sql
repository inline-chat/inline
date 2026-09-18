-- Reader-compatible expansion. Encryption is enabled only after every reader is updated.
ALTER TABLE "chats" ALTER COLUMN "title" TYPE text;
--> statement-breakpoint
ALTER TABLE "chats" ALTER COLUMN "emoji" TYPE text;
--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "title_hash" bytea;
--> statement-breakpoint
CREATE INDEX "chats_title_hash_idx" ON "chats" ("title_hash", "space_id", "created_by");
--> statement-breakpoint
ALTER TABLE "reactions" ADD COLUMN "emoji_hash" bytea;
--> statement-breakpoint
ALTER TABLE "reactions" ADD CONSTRAINT "reactions_identity_emoji_hash_unique" UNIQUE ("chat_id", "message_id", "user_id", "emoji_hash");

--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "hash_version" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "block_content_image_jobs" ADD COLUMN "hash_version" smallint DEFAULT 0 NOT NULL;
