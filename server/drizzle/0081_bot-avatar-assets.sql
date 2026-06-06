CREATE TABLE "bot_avatar_assets" (
	"id" serial PRIMARY KEY NOT NULL,
	"bot_user_id" integer NOT NULL,
	"kind" text NOT NULL,
	"display_name" varchar(256) NOT NULL,
	"description" text,
	"file_id" integer NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "bot_avatar_assets_bot_user_id_unique" UNIQUE("bot_user_id")
);
--> statement-breakpoint
ALTER TABLE "bot_avatar_assets" ADD CONSTRAINT "bot_avatar_assets_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bot_avatar_assets" ADD CONSTRAINT "bot_avatar_assets_file_id_files_id_fk" FOREIGN KEY ("file_id") REFERENCES "public"."files"("id") ON DELETE no action ON UPDATE no action;