CREATE TABLE "mcp_event_subscriptions" (
	"id" varchar(80) PRIMARY KEY NOT NULL,
	"grant_id" varchar(128) NOT NULL,
	"name" varchar(80) NOT NULL,
	"selector" jsonb NOT NULL,
	"callback_url" varchar(4096) NOT NULL,
	"secret_encrypted" "bytea" NOT NULL,
	"previous_secret_encrypted" "bytea",
	"previous_secret_until" timestamp (3),
	"verified_at" timestamp (3) NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"cursor_seq" integer NOT NULL,
	"gap_seq" integer,
	"pending_encrypted" "bytea",
	"pending_seq" integer,
	"attempt_count" integer DEFAULT 0 NOT NULL,
	"next_attempt_at" timestamp (3) DEFAULT now() NOT NULL,
	"lease_owner" varchar(36),
	"lease_until" timestamp (3),
	"generation" integer DEFAULT 0 NOT NULL,
	"stopped" boolean DEFAULT false NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "mcp_events_cursor_nonnegative" CHECK ("mcp_event_subscriptions"."cursor_seq" >= 0 AND ("mcp_event_subscriptions"."gap_seq" IS NULL OR "mcp_event_subscriptions"."gap_seq" >= "mcp_event_subscriptions"."cursor_seq")),
	CONSTRAINT "mcp_events_pending_pair" CHECK (("mcp_event_subscriptions"."pending_encrypted" IS NULL) = ("mcp_event_subscriptions"."pending_seq" IS NULL))
);
--> statement-breakpoint
ALTER TABLE "mcp_event_subscriptions" ADD CONSTRAINT "mcp_event_subscriptions_grant_id_oauth_grants_id_fk" FOREIGN KEY ("grant_id") REFERENCES "public"."oauth_grants"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "mcp_events_due_idx" ON "mcp_event_subscriptions" USING btree ("next_attempt_at","expires_at") WHERE "mcp_event_subscriptions"."stopped" = false AND "mcp_event_subscriptions"."gap_seq" IS NULL;--> statement-breakpoint
CREATE INDEX "mcp_events_grant_idx" ON "mcp_event_subscriptions" USING btree ("grant_id");--> statement-breakpoint
CREATE INDEX "mcp_events_expiry_idx" ON "mcp_event_subscriptions" USING btree ("expires_at");