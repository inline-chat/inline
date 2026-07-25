ALTER TABLE "oauth_auth_requests" ADD COLUMN "resource" text DEFAULT 'https://mcp.inline.chat' NOT NULL;--> statement-breakpoint
ALTER TABLE "oauth_grants" ADD COLUMN "resource" text DEFAULT 'https://mcp.inline.chat' NOT NULL;--> statement-breakpoint
UPDATE "oauth_refresh_tokens"
SET "expires_at" = GREATEST("expires_at", "date" + INTERVAL '180 days')
WHERE "revoked_at" IS NULL
  AND "expires_at" > NOW();
