CREATE TABLE IF NOT EXISTS "files" (
	"id" serial PRIMARY KEY NOT NULL,
	"file_unique_id" text NOT NULL,
	"path_encrypted" "bytea",
	"path_iv" "bytea",
	"path_tag" "bytea",
	"name_encrypted" "bytea",
	"name_iv" "bytea",
	"name_tag" "bytea",
	"file_size" integer,
	"mime_type" text,
	"file_type" text,
	"width" integer,
	"height" integer,
	"bytes_encrypted" "bytea",
	"bytes_iv" "bytea",
	"bytes_tag" "bytea",
	"thumb_size" text,
	"thumb_for" integer,
	"video_duration" double precision,
	"cdn" integer DEFAULT 1,
	"user_id" integer NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "files_file_unique_id_unique" UNIQUE("file_unique_id")
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "file_id" integer;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "files" ADD CONSTRAINT "files_thumb_for_files_id_fk" FOREIGN KEY ("thumb_for") REFERENCES "public"."files"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "files" ADD CONSTRAINT "files_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "messages" ADD CONSTRAINT "messages_file_id_files_id_fk" FOREIGN KEY ("file_id") REFERENCES "public"."files"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
