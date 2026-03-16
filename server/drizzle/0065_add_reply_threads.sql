ALTER TABLE "chats" ADD COLUMN "parent_chat_id" integer;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "parent_message_id" integer;--> statement-breakpoint
ALTER TABLE "chats" ADD CONSTRAINT "chats_parent_chat_id_chats_id_fk" FOREIGN KEY ("parent_chat_id") REFERENCES "public"."chats"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chats" ADD CONSTRAINT "parent_message_id_fk" FOREIGN KEY ("parent_chat_id","parent_message_id") REFERENCES "public"."messages"("chat_id","message_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "chats_parent_chat_id_idx" ON "chats" USING btree ("parent_chat_id");--> statement-breakpoint
ALTER TABLE "chats" ADD CONSTRAINT "reply_thread_parent_unique" UNIQUE("parent_chat_id","parent_message_id");--> statement-breakpoint
ALTER TABLE "chats" ADD CONSTRAINT "parent_message_requires_parent_chat" CHECK ("chats"."parent_message_id" is null or "chats"."parent_chat_id" is not null);