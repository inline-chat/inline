ALTER TABLE "messages" ADD COLUMN "rev" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "message_translations" ADD COLUMN "msg_rev" integer DEFAULT 0 NOT NULL;