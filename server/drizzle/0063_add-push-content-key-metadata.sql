ALTER TABLE "sessions" ADD COLUMN "push_content_key_public" "bytea";--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "push_content_key_id" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "push_content_key_algorithm" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "push_content_version" integer;