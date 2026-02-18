ALTER TABLE "login_codes" ALTER COLUMN "code" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "login_codes" ADD COLUMN "code_hash" text;