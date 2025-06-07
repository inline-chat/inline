ALTER TABLE "message_attachments" DROP CONSTRAINT "message_attachments_message_id_messages_global_id_fk";
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "bot" boolean DEFAULT false;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "bot_creator_id" integer;--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_bot_creator_id_users_id_fk" FOREIGN KEY ("bot_creator_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_attachments" ADD CONSTRAINT "message_attachments_message_id_messages_global_id_fk" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("global_id") ON DELETE cascade ON UPDATE no action;