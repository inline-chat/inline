ALTER TABLE "messages" ADD COLUMN "random_id" bigint;--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "random_id_per_sender_unique" UNIQUE("random_id","from_id");