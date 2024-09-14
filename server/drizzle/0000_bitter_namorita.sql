CREATE TABLE IF NOT EXISTS "waitlist" (
	"id" serial PRIMARY KEY NOT NULL,
	"email" varchar(256) NOT NULL,
	"verified" boolean DEFAULT false NOT NULL,
	"name" varchar(256),
	"user_agent" text,
	"date" timestamp with time zone DEFAULT now(),
	CONSTRAINT "waitlist_email_unique" UNIQUE("email")
);
