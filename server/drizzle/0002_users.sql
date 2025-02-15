CREATE SEQUENCE "public"."user_id" INCREMENT BY 3 MINVALUE 1000 MAXVALUE 9223372036854775807 START WITH 1000 CACHE 100;--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "users" (
	"id" bigint PRIMARY KEY DEFAULT nextval('user_id') NOT NULL,
	"email" varchar(256),
	"phone_number" varchar(15),
	"email_verified" boolean,
	"phone_verified" boolean,
	"first_name" varchar(256),
	"last_name" varchar(256),
	"deleted" boolean,
	"date" timestamp (3) DEFAULT now(),
	CONSTRAINT "users_email_unique" UNIQUE("email"),
	CONSTRAINT "users_phone_number_unique" UNIQUE("phone_number")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "sessions" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" bigint NOT NULL,
	"token_hash" varchar(64) NOT NULL,
	"revoked" timestamp (3),
	"last_active" timestamp (3),
	"date" timestamp (3)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "login_codes" (
	"id" serial PRIMARY KEY NOT NULL,
	"email" varchar(256),
	"phone_number" varchar(15),
	"code" varchar(10) NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"attempts" smallint DEFAULT 0,
	"date" timestamp (3) DEFAULT now(),
	CONSTRAINT "login_codes_email_unique" UNIQUE("email"),
	CONSTRAINT "login_codes_phone_number_unique" UNIQUE("phone_number")
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "sessions" ADD CONSTRAINT "sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
