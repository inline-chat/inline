CREATE TABLE IF NOT EXISTS "url_preview" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "url_preview_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"url" "bytea",
	"url_iv" "bytea",
	"url_tag" "bytea",
	"site_name" text,
	"title" "bytea",
	"title_iv" "bytea",
	"title_tag" "bytea",
	"description" "bytea",
	"description_iv" "bytea",
	"description_tag" "bytea",
	"photo_id" bigint,
	"duration" integer,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "message_attachments" ADD COLUMN "url_preview_id" bigint;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "url_preview" ADD CONSTRAINT "url_preview_photo_id_photos_id_fk" FOREIGN KEY ("photo_id") REFERENCES "public"."photos"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "message_attachments" ADD CONSTRAINT "message_attachments_url_preview_id_url_preview_id_fk" FOREIGN KEY ("url_preview_id") REFERENCES "public"."url_preview"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
