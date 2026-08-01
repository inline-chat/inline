CREATE TABLE "email_campaign_recipients" (
	"id" serial PRIMARY KEY NOT NULL,
	"campaign_id" integer NOT NULL,
	"email_key" varchar(64) NOT NULL,
	"email_encrypted" "bytea" NOT NULL,
	"name_encrypted" "bytea",
	"unsubscribe_token_hash" varchar(64) NOT NULL,
	"unsubscribe_token_encrypted" "bytea" NOT NULL,
	"sources" jsonb NOT NULL,
	"status" varchar(32) DEFAULT 'pending' NOT NULL,
	"attempt_count" integer DEFAULT 0 NOT NULL,
	"provider" varchar(32),
	"provider_message_id" varchar(256),
	"last_attempt_at" timestamp with time zone,
	"contacted_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "email_campaign_recipients_status_check" CHECK ("email_campaign_recipients"."status" in ('pending', 'provider_synced', 'sending', 'provider_accepted', 'unknown', 'suppressed'))
);
--> statement-breakpoint
CREATE TABLE "email_campaigns" (
	"id" serial PRIMARY KEY NOT NULL,
	"name" varchar(160) NOT NULL,
	"series_key" varchar(160),
	"subject" varchar(240) NOT NULL,
	"preview_text" varchar(240),
	"body_text" text NOT NULL,
	"audience" jsonb NOT NULL,
	"status" varchar(32) DEFAULT 'frozen' NOT NULL,
	"recipient_count" integer DEFAULT 0 NOT NULL,
	"provider_segment_id" varchar(256),
	"provider_campaign_id" varchar(256),
	"created_by_user_id" integer NOT NULL,
	"visible_unsubscribe" boolean DEFAULT true NOT NULL,
	"unsubscribe_override_reason" text,
	"test_sent_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"frozen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"completed_at" timestamp with time zone,
	CONSTRAINT "email_campaigns_status_check" CHECK ("email_campaigns"."status" in ('frozen', 'sending', 'paused', 'completed'))
);
--> statement-breakpoint
CREATE TABLE "email_suppressions" (
	"id" serial PRIMARY KEY NOT NULL,
	"email_key" varchar(64) NOT NULL,
	"email_encrypted" "bytea" NOT NULL,
	"reason" varchar(32) NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "email_suppressions_reason_check" CHECK ("email_suppressions"."reason" in ('unsubscribe', 'manual', 'bounce', 'complaint', 'invalid'))
);
--> statement-breakpoint
ALTER TABLE "email_campaign_recipients" ADD CONSTRAINT "email_campaign_recipients_campaign_id_email_campaigns_id_fk" FOREIGN KEY ("campaign_id") REFERENCES "public"."email_campaigns"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "email_campaigns" ADD CONSTRAINT "email_campaigns_created_by_user_id_users_id_fk" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "email_campaign_recipients_campaign_email_unique" ON "email_campaign_recipients" USING btree ("campaign_id","email_key");--> statement-breakpoint
CREATE UNIQUE INDEX "email_campaign_recipients_unsubscribe_token_unique" ON "email_campaign_recipients" USING btree ("unsubscribe_token_hash");--> statement-breakpoint
CREATE INDEX "email_campaign_recipients_campaign_status_idx" ON "email_campaign_recipients" USING btree ("campaign_id","status","id");--> statement-breakpoint
CREATE INDEX "email_campaign_recipients_email_key_idx" ON "email_campaign_recipients" USING btree ("email_key");--> statement-breakpoint
CREATE UNIQUE INDEX "email_campaigns_name_unique" ON "email_campaigns" USING btree ("name");--> statement-breakpoint
CREATE INDEX "email_campaigns_created_at_idx" ON "email_campaigns" USING btree ("created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "email_suppressions_email_key_unique" ON "email_suppressions" USING btree ("email_key");
