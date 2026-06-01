CREATE TABLE "url_preview_cache" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "url_preview_cache_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"url_hash" "bytea" NOT NULL,
	"url" "bytea" NOT NULL,
	"url_iv" "bytea" NOT NULL,
	"url_tag" "bytea" NOT NULL,
	"final_url" "bytea",
	"final_url_iv" "bytea",
	"final_url_tag" "bytea",
	"provider" text DEFAULT 'generic' NOT NULL,
	"site_name" text,
	"title" "bytea",
	"title_iv" "bytea",
	"title_tag" "bytea",
	"description" "bytea",
	"description_iv" "bytea",
	"description_tag" "bytea",
	"image_url_hash" "bytea",
	"image_url" "bytea",
	"image_url_iv" "bytea",
	"image_url_tag" "bytea",
	"photo_id" bigint,
	"duration" integer,
	"fetched_at" timestamp (3) NOT NULL,
	"last_used_at" timestamp (3) NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "cache_id" bigint;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD CONSTRAINT "url_preview_cache_photo_id_photos_id_fk" FOREIGN KEY ("photo_id") REFERENCES "public"."photos"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "url_preview_cache_url_hash_unique" ON "url_preview_cache" USING btree ("url_hash");--> statement-breakpoint
CREATE INDEX "url_preview_cache_image_url_hash_idx" ON "url_preview_cache" USING btree ("image_url_hash");--> statement-breakpoint
CREATE INDEX "url_preview_cache_expires_at_idx" ON "url_preview_cache" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "url_preview_cache_last_used_at_idx" ON "url_preview_cache" USING btree ("last_used_at");--> statement-breakpoint
ALTER TABLE "url_preview" ADD CONSTRAINT "url_preview_cache_id_url_preview_cache_id_fk" FOREIGN KEY ("cache_id") REFERENCES "public"."url_preview_cache"("id") ON DELETE no action ON UPDATE no action;