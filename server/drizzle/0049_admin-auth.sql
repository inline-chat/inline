CREATE TABLE "admin_sessions" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"token_hash" varchar(64) NOT NULL,
	"revoked_at" timestamp (3),
	"last_seen_at" timestamp (3),
	"expires_at" timestamp (3) NOT NULL,
	"idle_expires_at" timestamp (3) NOT NULL,
	"ip" text,
	"user_agent_hash" varchar(64),
	"date" timestamp (3) DEFAULT now(),
	CONSTRAINT "admin_sessions_token_hash_unique" UNIQUE("token_hash")
);
--> statement-breakpoint
CREATE TABLE "superadmin_users" (
	"id" serial PRIMARY KEY NOT NULL,
	"email" varchar(256) NOT NULL,
	"user_id" integer,
	"disabled_at" timestamp (3),
	"date" timestamp (3) DEFAULT now(),
	CONSTRAINT "superadmin_users_email_unique" UNIQUE("email"),
	CONSTRAINT "superadmin_users_user_id_unique" UNIQUE("user_id")
);
--> statement-breakpoint
ALTER TABLE "admin_sessions" ADD CONSTRAINT "admin_sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD CONSTRAINT "superadmin_users_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;