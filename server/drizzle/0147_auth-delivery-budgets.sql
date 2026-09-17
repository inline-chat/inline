CREATE TABLE "auth_delivery_budgets" (
  "key" varchar(96) PRIMARY KEY NOT NULL,
  "attempts" integer NOT NULL,
  "expires_at" timestamp(3) with time zone NOT NULL,
  CONSTRAINT "auth_delivery_budgets_attempts_positive" CHECK ("attempts" > 0)
);
--> statement-breakpoint
CREATE INDEX "auth_delivery_budgets_expiry_idx" ON "auth_delivery_budgets" ("expires_at");
