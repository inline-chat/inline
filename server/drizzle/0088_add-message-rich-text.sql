ALTER TABLE "messages" ADD COLUMN "rich_text_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "rich_text_iv" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "rich_text_tag" "bytea";