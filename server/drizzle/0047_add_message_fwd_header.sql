ALTER TABLE "messages" ADD COLUMN "fwd_from_peer_user_id" integer;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "fwd_from_peer_chat_id" integer;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "fwd_from_message_id" integer;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "fwd_from_sender_id" integer;