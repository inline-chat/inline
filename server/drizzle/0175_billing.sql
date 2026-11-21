CREATE TABLE "billing_events" (
	"id" varchar(255) PRIMARY KEY NOT NULL,
	"order_id" varchar(64),
	"type" varchar(64) NOT NULL,
	"received_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "billing_orders" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"buyer_user_id" integer NOT NULL,
	"user_id" integer,
	"space_id" integer,
	"plan_code" varchar(64) NOT NULL,
	"quantity" integer DEFAULT 1 NOT NULL,
	"status" varchar(16) NOT NULL,
	"livemode" boolean DEFAULT false NOT NULL,
	"checkout_session_id" varchar(255),
	"checkout_url" text,
	"stripe_subscription_id" varchar(255),
	"payment_intent_id" varchar(255),
	"subscription_id" integer,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "billing_orders_subject_check" CHECK (("billing_orders"."user_id" is null) <> ("billing_orders"."space_id" is null))
);
--> statement-breakpoint
CREATE TABLE "billing_subscriptions" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer,
	"space_id" integer,
	"plan" varchar(32) NOT NULL,
	"interval" varchar(16) NOT NULL,
	"funding" varchar(16) NOT NULL,
	"status" varchar(32) NOT NULL,
	"seats" integer DEFAULT 1 NOT NULL,
	"paid_through" timestamp (3) with time zone,
	"cancel_at_period_end" boolean DEFAULT false NOT NULL,
	"payer_user_id" integer,
	"stripe_subscription_id" varchar(255),
	"livemode" boolean DEFAULT false NOT NULL,
	"note" text,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"ended_at" timestamp (3) with time zone,
	CONSTRAINT "billing_subscriptions_subject_check" CHECK (("billing_subscriptions"."user_id" is null) <> ("billing_subscriptions"."space_id" is null))
);
--> statement-breakpoint
CREATE TABLE "billing_wallet_entries" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer,
	"space_id" integer,
	"currency" varchar(8) NOT NULL,
	"amount" bigint NOT NULL,
	"kind" varchar(32) NOT NULL,
	"reference" text,
	"subscription_id" integer,
	"admin_id" integer,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "billing_wallet_entries_subject_check" CHECK (("billing_wallet_entries"."user_id" is null) <> ("billing_wallet_entries"."space_id" is null)),
	CONSTRAINT "billing_wallet_entries_currency_check" CHECK ("billing_wallet_entries"."currency" in ('usd', 'btc'))
);
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "is_pro" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "billing_orders" ADD CONSTRAINT "billing_orders_buyer_user_id_users_id_fk" FOREIGN KEY ("buyer_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_orders" ADD CONSTRAINT "billing_orders_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_orders" ADD CONSTRAINT "billing_orders_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_orders" ADD CONSTRAINT "billing_orders_subscription_id_billing_subscriptions_id_fk" FOREIGN KEY ("subscription_id") REFERENCES "public"."billing_subscriptions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_subscriptions" ADD CONSTRAINT "billing_subscriptions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_subscriptions" ADD CONSTRAINT "billing_subscriptions_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_subscriptions" ADD CONSTRAINT "billing_subscriptions_payer_user_id_users_id_fk" FOREIGN KEY ("payer_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_wallet_entries" ADD CONSTRAINT "billing_wallet_entries_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_wallet_entries" ADD CONSTRAINT "billing_wallet_entries_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_wallet_entries" ADD CONSTRAINT "billing_wallet_entries_subscription_id_billing_subscriptions_id_fk" FOREIGN KEY ("subscription_id") REFERENCES "public"."billing_subscriptions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "billing_wallet_entries" ADD CONSTRAINT "billing_wallet_entries_admin_id_superadmin_users_id_fk" FOREIGN KEY ("admin_id") REFERENCES "public"."superadmin_users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "billing_orders_checkout_session_unique" ON "billing_orders" USING btree ("checkout_session_id");--> statement-breakpoint
CREATE INDEX "billing_orders_buyer_idx" ON "billing_orders" USING btree ("buyer_user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "billing_subscriptions_live_user_unique" ON "billing_subscriptions" USING btree ("user_id") WHERE "billing_subscriptions"."ended_at" is null and "billing_subscriptions"."user_id" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "billing_subscriptions_live_space_unique" ON "billing_subscriptions" USING btree ("space_id") WHERE "billing_subscriptions"."ended_at" is null and "billing_subscriptions"."space_id" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "billing_subscriptions_stripe_unique" ON "billing_subscriptions" USING btree ("stripe_subscription_id");--> statement-breakpoint
CREATE INDEX "billing_subscriptions_paid_through_idx" ON "billing_subscriptions" USING btree ("paid_through") WHERE "billing_subscriptions"."ended_at" is null;--> statement-breakpoint
CREATE INDEX "billing_wallet_entries_user_idx" ON "billing_wallet_entries" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "billing_wallet_entries_space_idx" ON "billing_wallet_entries" USING btree ("space_id");--> statement-breakpoint
-- Spaces marked Pro by hand keep Pro as open-ended comps.
INSERT INTO "billing_subscriptions" ("space_id", "plan", "interval", "funding", "status", "note")
SELECT "id", 'team', 'none', 'comp', 'active', 'backfilled from hand-set spaces.is_pro'
FROM "spaces" WHERE "is_pro" = true AND "deleted" IS NULL;
