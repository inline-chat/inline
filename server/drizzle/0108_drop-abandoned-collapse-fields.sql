-- Remove columns left by the abandoned pre-v0.1 collapse implementation.
ALTER TABLE "dialogs" DROP COLUMN IF EXISTS "collapsed_at";--> statement-breakpoint
ALTER TABLE "chats" DROP COLUMN IF EXISTS "message_id_high_water";
