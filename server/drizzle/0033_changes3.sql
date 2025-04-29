ALTER TABLE "link_embed_experimental" RENAME COLUMN "provider" TO "provider_name";--> statement-breakpoint
ALTER TABLE "link_embed_experimental" ADD COLUMN "provider_url" text;