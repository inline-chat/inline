ALTER TABLE "messages" DROP CONSTRAINT "messages_peer_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "applePushToken" text;--> statement-breakpoint
ALTER TABLE "messages" DROP COLUMN IF EXISTS "peer_user_id";