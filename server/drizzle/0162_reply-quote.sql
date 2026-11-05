ALTER TABLE "messages" ADD COLUMN "reply_quote_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "reply_quote_iv" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "reply_quote_tag" "bytea";