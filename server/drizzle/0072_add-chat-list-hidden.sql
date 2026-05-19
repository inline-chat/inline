ALTER TABLE "dialogs" ADD COLUMN "chat_list_hidden" boolean;--> statement-breakpoint
UPDATE "dialogs"
SET "chat_list_hidden" = true
WHERE "chat_list_hidden" IS NULL AND "sidebar_visible" = false;
