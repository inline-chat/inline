CREATE TABLE "agent_settings" (
	"bot_user_id" integer PRIMARY KEY NOT NULL,
	"default_output_mode" smallint DEFAULT 0 NOT NULL,
	"revision" bigint DEFAULT 1 NOT NULL,
	"updated_by" integer,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "agent_settings" ADD CONSTRAINT "agent_settings_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_settings" ADD CONSTRAINT "agent_settings_updated_by_users_id_fk" FOREIGN KEY ("updated_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
-- Output mode moves from the bridge runtime to per-bot settings.
INSERT INTO "agent_settings" ("bot_user_id", "default_output_mode")
SELECT "bot_user_id", "default_output_mode" FROM "agent_runtimes" WHERE "default_output_mode" <> 0
ON CONFLICT ("bot_user_id") DO NOTHING;