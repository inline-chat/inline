CREATE TABLE "reserved_usernames" (
	"username" varchar(256) PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
