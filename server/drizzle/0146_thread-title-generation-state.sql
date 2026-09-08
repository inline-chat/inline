-- Keep existing rows unknown so previously successful titles remain stable.
ALTER TABLE "chats" ADD COLUMN "auto_title_generated" boolean;
--> statement-breakpoint
ALTER TABLE "chats" ALTER COLUMN "auto_title_generated" SET DEFAULT false;
