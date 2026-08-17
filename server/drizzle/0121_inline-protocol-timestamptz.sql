ALTER TABLE "inline_protocol_auth_challenges" ALTER COLUMN "created_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_challenges" ALTER COLUMN "created_at" SET DEFAULT now();--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_challenges" ALTER COLUMN "expires_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_challenges" ALTER COLUMN "consumed_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "server_salt_updated_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "server_salt_updated_at" SET DEFAULT now();--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "created_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "created_at" SET DEFAULT now();--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "authorized_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "last_used_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "expires_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ALTER COLUMN "revoked_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" ALTER COLUMN "claimed_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" ALTER COLUMN "claimed_at" SET DEFAULT now();--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" ALTER COLUMN "completed_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" ALTER COLUMN "expires_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ALTER COLUMN "locked_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ALTER COLUMN "created_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ALTER COLUMN "created_at" SET DEFAULT now();--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ALTER COLUMN "expires_at" SET DATA TYPE timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ALTER COLUMN "completed_at" SET DATA TYPE timestamp (3) with time zone;