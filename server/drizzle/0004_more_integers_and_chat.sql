ALTER TABLE "messages" RENAME COLUMN "id" TO "global_id";--> statement-breakpoint
ALTER TABLE "users" ALTER COLUMN "id" SET DATA TYPE integer;--> statement-breakpoint
ALTER TABLE "sessions" ALTER COLUMN "user_id" SET DATA TYPE integer;--> statement-breakpoint
ALTER TABLE "members" ALTER COLUMN "user_id" SET DATA TYPE integer;--> statement-breakpoint
ALTER TABLE "chats" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (sequence name "chats_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1);--> statement-breakpoint
ALTER TABLE "chats" ALTER COLUMN "title" SET DATA TYPE varchar(150);--> statement-breakpoint
ALTER TABLE "chats" ALTER COLUMN "min_user_id" SET DATA TYPE integer;--> statement-breakpoint
ALTER TABLE "chats" ALTER COLUMN "max_user_id" SET DATA TYPE integer;--> statement-breakpoint
ALTER TABLE "messages" ALTER COLUMN "from_id" SET DATA TYPE integer;--> statement-breakpoint
ALTER TABLE "dialogs" ALTER COLUMN "user_id" SET DATA TYPE integer;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "description" text;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "emoji" varchar(20);--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "max_msg_id" integer;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "space_public" boolean;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "thread_number" integer;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "chats" ADD CONSTRAINT "max_msg_id_fk" FOREIGN KEY ("id","max_msg_id") REFERENCES "public"."messages"("chat_id","message_id") ON DELETE set null ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
ALTER TABLE "chats" ADD CONSTRAINT "space_thread_number_unique" UNIQUE("space_id","thread_number");