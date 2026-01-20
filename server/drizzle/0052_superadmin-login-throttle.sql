ALTER TABLE "superadmin_users" ADD COLUMN "failed_login_attempts" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "last_login_attempt_at" timestamp (3);--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "login_locked_until" timestamp (3);