ALTER TABLE "inline_upload_parts" ALTER COLUMN "stored_byte_count" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ALTER COLUMN "stored_sha256" DROP NOT NULL;