ALTER TABLE "sessions" ADD COLUMN "personal_data_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "personal_data_iv" "bytea";--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "personal_data_tag" "bytea";--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "apple_push_token_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "apple_push_token_iv" "bytea";--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "apple_push_token_tag" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "text_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "text_iv" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "text_tag" "bytea";--> statement-breakpoint
ALTER TABLE "sessions" DROP COLUMN IF EXISTS "country";--> statement-breakpoint
ALTER TABLE "sessions" DROP COLUMN IF EXISTS "region";--> statement-breakpoint
ALTER TABLE "sessions" DROP COLUMN IF EXISTS "city";--> statement-breakpoint
ALTER TABLE "sessions" DROP COLUMN IF EXISTS "timezone";--> statement-breakpoint
ALTER TABLE "sessions" DROP COLUMN IF EXISTS "ip";--> statement-breakpoint
ALTER TABLE "sessions" DROP COLUMN IF EXISTS "deviceName";