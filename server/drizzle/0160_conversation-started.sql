-- Chats that already exist have had their opening message, so their bots stay as they are.
ALTER TABLE "chats" ADD COLUMN "conversation_started" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "chats" ALTER COLUMN "conversation_started" SET DEFAULT false;
