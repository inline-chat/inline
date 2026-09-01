ALTER TABLE "chat_acknowledgements" ADD COLUMN "revision" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "chat_acknowledgements" ADD COLUMN "cleared" boolean DEFAULT false NOT NULL;
