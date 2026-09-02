CREATE TABLE "subthread_parent_messages" (
	"child_chat_id" integer PRIMARY KEY NOT NULL,
	"parent_message_global_id" bigint,
	CONSTRAINT "subthread_parent_messages_parent_message_unique" UNIQUE("parent_message_global_id")
);
--> statement-breakpoint
ALTER TABLE "subthread_parent_messages" ADD CONSTRAINT "subthread_parent_messages_child_chat_fk" FOREIGN KEY ("child_chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "subthread_parent_messages" ADD CONSTRAINT "subthread_parent_messages_parent_message_fk" FOREIGN KEY ("parent_message_global_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;