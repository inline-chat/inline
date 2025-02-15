ALTER TABLE "chats" DROP CONSTRAINT "user_ids_check";--> statement-breakpoint
ALTER TABLE "chats" ADD CONSTRAINT "user_ids_check" CHECK ("chats"."min_user_id" <= "chats"."max_user_id");