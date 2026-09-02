CREATE TABLE "inline_upload_storage_parts" (
	"upload_id" bigint NOT NULL,
	"storage_upload_id" text NOT NULL,
	"part_number" integer NOT NULL,
	"stored_byte_count" integer NOT NULL,
	"stored_sha256" "bytea" NOT NULL,
	"etag" text NOT NULL,
	"completed_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "inline_upload_storage_parts_pk" PRIMARY KEY("upload_id","part_number"),
	CONSTRAINT "inline_upload_storage_parts_number_valid" CHECK ("inline_upload_storage_parts"."part_number" between 1 and 1000),
	CONSTRAINT "inline_upload_storage_parts_byte_count_valid" CHECK ("inline_upload_storage_parts"."stored_byte_count" > 0),
	CONSTRAINT "inline_upload_storage_parts_sha_length" CHECK (octet_length("inline_upload_storage_parts"."stored_sha256") = 32),
	CONSTRAINT "inline_upload_storage_parts_etag_valid" CHECK (length("inline_upload_storage_parts"."etag") between 1 and 128)
);
--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ADD COLUMN "stored_byte_count" integer;--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ADD COLUMN "stored_sha256" "bytea";--> statement-breakpoint
UPDATE "inline_upload_parts" SET
	"stored_byte_count" = "byte_count",
	"stored_sha256" = "sha256";--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ALTER COLUMN "stored_byte_count" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ALTER COLUMN "stored_sha256" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD COLUMN "storage_format" varchar(32);--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD COLUMN "storage_upload_id" text;--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD COLUMN "retry_at" timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD COLUMN "attempts" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "inline_upload_storage_parts" ADD CONSTRAINT "inline_upload_storage_parts_upload_id_inline_uploads_id_fk" FOREIGN KEY ("upload_id") REFERENCES "public"."inline_uploads"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "inline_uploads_processing_retry_idx" ON "inline_uploads" USING btree ("status","retry_at");--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ADD CONSTRAINT "inline_upload_parts_stored_byte_count_valid" CHECK ("inline_upload_parts"."stored_byte_count" > 0);--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ADD CONSTRAINT "inline_upload_parts_stored_sha_length" CHECK (octet_length("inline_upload_parts"."stored_sha256") = 32);--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD CONSTRAINT "inline_uploads_storage_format_valid" CHECK ("inline_uploads"."storage_format" is null or "inline_uploads"."storage_format" = 'identity_v1');--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD CONSTRAINT "inline_uploads_storage_session_valid" CHECK ("inline_uploads"."storage_upload_id" is null or "inline_uploads"."storage_format" is not null);--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD CONSTRAINT "inline_uploads_attempts_valid" CHECK ("inline_uploads"."attempts" >= 0);
