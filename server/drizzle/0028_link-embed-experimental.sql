CREATE TYPE "public"."link_embed_type" AS ENUM('link', 'loom');--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "link_embed_experimental" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "link_embed_experimental_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"url" text NOT NULL,
	"type" "link_embed_type" DEFAULT 'link' NOT NULL,
	"provider" text,
	"title" text,
	"description" text,
	"image_url" varchar(2048),
	"image_width" integer,
	"image_height" integer,
	"html" text,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "message_attachments" ADD COLUMN "link_embed_id" bigint;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "message_attachments" ADD CONSTRAINT "message_attachments_link_embed_id_link_embed_experimental_id_fk" FOREIGN KEY ("link_embed_id") REFERENCES "public"."link_embed_experimental"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
