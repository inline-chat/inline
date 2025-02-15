ALTER TABLE "chats" RENAME COLUMN "max_msg_id" TO "last_msg_id";--> statement-breakpoint
ALTER TABLE "chats" RENAME COLUMN "space_public" TO "public_thread";--> statement-breakpoint
ALTER TABLE "chats" DROP CONSTRAINT "max_msg_id_fk";
--> statement-breakpoint
ALTER TABLE "dialogs" ALTER COLUMN "user_id" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "peer_user_id" integer;--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "space_id" integer;--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "read_inbox_max_id" integer;--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "read_outbox_max_id" integer;--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "pinned" boolean;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "chats" ADD CONSTRAINT "last_msg_id_fk" FOREIGN KEY ("id","last_msg_id") REFERENCES "public"."messages"("chat_id","message_id") ON DELETE set null ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "dialogs" ADD CONSTRAINT "dialogs_peer_user_id_users_id_fk" FOREIGN KEY ("peer_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "dialogs" ADD CONSTRAINT "dialogs_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
