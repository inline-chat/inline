ALTER TABLE "url_preview" ADD COLUMN "author_photo_id" bigint;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author_image_url_hash" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author_image_url" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author_image_url_iv" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author_image_url_tag" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author_photo_id" bigint;--> statement-breakpoint
ALTER TABLE "url_preview" ADD CONSTRAINT "url_preview_author_photo_id_photos_id_fk" FOREIGN KEY ("author_photo_id") REFERENCES "public"."photos"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD CONSTRAINT "url_preview_cache_author_photo_id_photos_id_fk" FOREIGN KEY ("author_photo_id") REFERENCES "public"."photos"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "url_preview_cache_author_image_url_hash_idx" ON "url_preview_cache" USING btree ("author_image_url_hash");