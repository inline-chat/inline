ALTER TABLE "users" ADD COLUMN "update_seq" integer;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "last_update_date" timestamp (3);