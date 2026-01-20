ALTER TABLE "superadmin_sessions" ADD COLUMN "step_up_at" timestamp (3);--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "password_hash" text;--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "password_set_at" timestamp (3);--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "totp_secret_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "totp_secret_iv" "bytea";--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "totp_secret_tag" "bytea";--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "totp_enabled_at" timestamp (3);--> statement-breakpoint
ALTER TABLE "superadmin_users" ADD COLUMN "totp_last_used_at" timestamp (3);