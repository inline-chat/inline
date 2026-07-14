CREATE TABLE "bot_capabilities" (
	"id" serial PRIMARY KEY NOT NULL,
	"bot_user_id" integer NOT NULL,
	"kind" varchar(64) NOT NULL,
	"version" integer NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "bot_capabilities" ADD CONSTRAINT "bot_capabilities_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "bot_capabilities_bot_user_id_kind_unique" ON "bot_capabilities" USING btree ("bot_user_id","kind");
