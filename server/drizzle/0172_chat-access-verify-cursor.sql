ALTER TABLE "chat_access_state" ADD COLUMN "verify_cursor" integer;--> statement-breakpoint
ALTER TABLE "chat_access_state" ADD COLUMN "verified_at" timestamp (3) with time zone;