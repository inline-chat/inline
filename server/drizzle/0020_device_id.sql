ALTER TABLE "sessions" ADD COLUMN "device_id" text;--> statement-breakpoint
ALTER TABLE "sessions" ADD CONSTRAINT "device_id_user_unique" UNIQUE("device_id","user_id");