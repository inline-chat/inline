ALTER TABLE "spaces" ADD COLUMN "photo_file_unique_id" varchar(128) REFERENCES "files"("file_unique_id") ON DELETE SET NULL;
--> statement-breakpoint
ALTER TABLE "spaces" ADD COLUMN "is_pro" boolean DEFAULT false NOT NULL;
