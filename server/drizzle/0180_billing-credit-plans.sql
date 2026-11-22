ALTER TABLE "billing_subscriptions" ADD COLUMN "charge_amount" bigint;--> statement-breakpoint
ALTER TABLE "billing_subscriptions" ADD COLUMN "charge_currency" varchar(8);--> statement-breakpoint
ALTER TABLE "billing_subscriptions" ADD COLUMN "charge_interval" varchar(16);--> statement-breakpoint
ALTER TABLE "billing_subscriptions" ADD COLUMN "charge_usd_cents" integer;--> statement-breakpoint
ALTER TABLE "billing_wallet_entries" ADD COLUMN "period_start" timestamp (3) with time zone;--> statement-breakpoint
CREATE UNIQUE INDEX "billing_wallet_entries_period_unique" ON "billing_wallet_entries" USING btree ("subscription_id","period_start") WHERE "billing_wallet_entries"."period_start" is not null;--> statement-breakpoint
ALTER TABLE "billing_subscriptions" ADD CONSTRAINT "billing_subscriptions_charge_check" CHECK (("billing_subscriptions"."charge_amount" is null) = ("billing_subscriptions"."charge_currency" is null) and ("billing_subscriptions"."charge_amount" is null) = ("billing_subscriptions"."charge_interval" is null) and ("billing_subscriptions"."charge_amount" is null or "billing_subscriptions"."charge_amount" > 0));