ALTER TABLE "inline_uploads" DROP CONSTRAINT "inline_uploads_storage_format_valid";--> statement-breakpoint
ALTER TABLE "inline_uploads" ALTER COLUMN "byte_count" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "inline_uploads" ALTER COLUMN "sha256" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "inline_uploads" ALTER COLUMN "part_count" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "inline_upload_storage_parts" ADD COLUMN "part_hashes" "bytea";--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD CONSTRAINT "inline_uploads_storage_format_valid" CHECK ("inline_uploads"."storage_format" is null or "inline_uploads"."storage_format" in ('identity_v1', 'blocks_v1'));