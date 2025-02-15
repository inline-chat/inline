CREATE TYPE "public"."member_roles" AS ENUM('owner', 'admin', 'member');--> statement-breakpoint
CREATE TYPE "public"."chat_types" AS ENUM('private', 'thread');--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "spaces" (
	"id" serial PRIMARY KEY NOT NULL,
	"name" varchar(256) NOT NULL,
	"handle" varchar(32),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "spaces_handle_unique" UNIQUE("handle")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "members" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" bigint NOT NULL,
	"space_id" integer NOT NULL,
	"role" "member_roles" DEFAULT 'member',
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "members_user_id_space_id_unique" UNIQUE("user_id","space_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "chats" (
	"id" integer PRIMARY KEY NOT NULL,
	"type" "chat_types" NOT NULL,
	"title" varchar,
	"space_id" integer,
	"min_user_id" bigint,
	"max_user_id" bigint,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "user_ids_unique" UNIQUE("min_user_id","max_user_id"),
	CONSTRAINT "user_ids_check" CHECK ("chats"."min_user_id" < "chats"."max_user_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "messages" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"message_id" integer NOT NULL,
	"text" text,
	"chat_id" integer NOT NULL,
	"from_id" bigint NOT NULL,
	"edit_date" timestamp (3),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "msg_id_per_chat_unique" UNIQUE("message_id","chat_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "dialogs" (
	"id" serial PRIMARY KEY NOT NULL,
	"chat_id" integer,
	"user_id" bigint,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "chat_id_user_id_unique" UNIQUE("chat_id","user_id")
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "members" ADD CONSTRAINT "members_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "members" ADD CONSTRAINT "members_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "chats" ADD CONSTRAINT "chats_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "chats" ADD CONSTRAINT "chats_min_user_id_users_id_fk" FOREIGN KEY ("min_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "chats" ADD CONSTRAINT "chats_max_user_id_users_id_fk" FOREIGN KEY ("max_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "messages" ADD CONSTRAINT "messages_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "messages" ADD CONSTRAINT "messages_from_id_users_id_fk" FOREIGN KEY ("from_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "dialogs" ADD CONSTRAINT "dialogs_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "dialogs" ADD CONSTRAINT "dialogs_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "msg_id_per_chat_index" ON "messages" USING btree ("message_id","chat_id");