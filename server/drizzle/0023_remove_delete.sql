ALTER TABLE "chats" DROP CONSTRAINT "last_msg_id_fk";
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "chats" ADD CONSTRAINT "last_msg_id_fk" FOREIGN KEY ("id","last_msg_id") REFERENCES "public"."messages"("chat_id","message_id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
