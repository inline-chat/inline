ALTER TABLE "users" ADD COLUMN "badge" varchar(16);--> statement-breakpoint
UPDATE "users" SET "badge" = CASE WHEN s."plan" = 'believer' THEN 'believer' ELSE 'pro' END
FROM "billing_subscriptions" s
WHERE s."user_id" = "users"."id" AND s."ended_at" IS NULL AND "users"."is_pro" = true;
