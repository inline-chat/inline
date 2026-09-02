CREATE TABLE "bot_skills" (
	"id" serial PRIMARY KEY NOT NULL,
	"bot_user_id" integer NOT NULL,
	"key" varchar(256) NOT NULL,
	"name" varchar(256) NOT NULL,
	"description" text,
	"sort_order" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "bot_skills" ADD CONSTRAINT "bot_skills_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "bot_skills_bot_user_id_key_unique" ON "bot_skills" USING btree ("bot_user_id","key");