ALTER TABLE "messages" DROP CONSTRAINT "messages_peer_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "random_id" bigint;--> statement-breakpoint
ALTER TABLE "messages" DROP COLUMN IF EXISTS "peer_user_id";--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "random_id_per_sender_unique" UNIQUE("random_id","from_id");