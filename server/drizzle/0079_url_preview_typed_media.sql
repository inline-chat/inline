ALTER TABLE "url_preview" ADD COLUMN "provider" text DEFAULT 'generic' NOT NULL;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "author" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "author_iv" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "author_tag" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "media_kind" text;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "video_id" bigint;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "document_id" bigint;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "external_url" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "external_url_iv" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "external_url_tag" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "external_mime_type" text;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "external_width" integer;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "external_height" integer;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "external_duration" integer;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "embed_url" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "embed_url_iv" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "embed_url_tag" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "embed_type" text;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "embed_width" integer;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "embed_height" integer;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "embed_duration" integer;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "has_large_media" boolean;--> statement-breakpoint
ALTER TABLE "url_preview" ADD COLUMN "show_large_media" boolean;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author_iv" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "author_tag" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "media_kind" text;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "video_id" bigint;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "document_id" bigint;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "external_url" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "external_url_iv" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "external_url_tag" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "external_mime_type" text;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "external_width" integer;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "external_height" integer;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "external_duration" integer;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "embed_url" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "embed_url_iv" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "embed_url_tag" "bytea";--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "embed_type" text;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "embed_width" integer;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "embed_height" integer;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "embed_duration" integer;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "has_large_media" boolean;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD COLUMN "show_large_media" boolean;--> statement-breakpoint
ALTER TABLE "url_preview" ADD CONSTRAINT "url_preview_video_id_videos_id_fk" FOREIGN KEY ("video_id") REFERENCES "public"."videos"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "url_preview" ADD CONSTRAINT "url_preview_document_id_documents_id_fk" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD CONSTRAINT "url_preview_cache_video_id_videos_id_fk" FOREIGN KEY ("video_id") REFERENCES "public"."videos"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "url_preview_cache" ADD CONSTRAINT "url_preview_cache_document_id_documents_id_fk" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE no action ON UPDATE no action;