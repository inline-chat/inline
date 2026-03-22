ALTER TABLE "messages" ADD COLUMN "actions_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "actions_iv" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "actions_tag" "bytea";