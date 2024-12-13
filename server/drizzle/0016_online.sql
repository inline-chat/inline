ALTER TABLE "users" ADD COLUMN "online" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "last_online" timestamp (3);--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "active" boolean DEFAULT false NOT NULL;