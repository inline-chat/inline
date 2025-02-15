CREATE TYPE "public"."client_type" AS ENUM('ios', 'macos', 'web');--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "country" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "region" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "city" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "timezone" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "ip" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "deviceName" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "client_type" "client_type";--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "clientVersion" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "osVersion" text;