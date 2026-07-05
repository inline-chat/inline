ALTER TABLE "videos" ADD COLUMN "is_animated" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "videos" ADD COLUMN "has_audio" boolean;