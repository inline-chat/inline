CREATE TABLE "bot_agents" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"bot_user_id" integer NOT NULL,
	"name" varchar(256) NOT NULL,
	"handle" varchar(256),
	"emoji" varchar(64),
	"description" text,
	"skill_key" varchar(256),
	"instructions_encrypted" "bytea",
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "bot_agents" ADD CONSTRAINT "bot_agents_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;