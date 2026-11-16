ALTER TABLE "messages" ADD COLUMN "via_app" varchar(32);--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "via_bot_user_id" integer;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "via_name" varchar(64);--> statement-breakpoint
ALTER TABLE "oauth_grants" ADD COLUMN "allow_unsigned" boolean DEFAULT false NOT NULL;