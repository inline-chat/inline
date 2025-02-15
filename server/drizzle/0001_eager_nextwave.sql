CREATE TABLE IF NOT EXISTS "there_users" (
	"id" serial PRIMARY KEY NOT NULL,
	"email" varchar(256) NOT NULL,
	"name" varchar(256),
	"time_zone" varchar(256),
	"date" timestamp with time zone DEFAULT now(),
	CONSTRAINT "there_users_email_unique" UNIQUE("email")
);
