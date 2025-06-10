ALTER TABLE "messages" ADD COLUMN "entities_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "entities_iv" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "entities_tag" "bytea";