ALTER TABLE "login_codes" DROP CONSTRAINT "login_codes_email_unique";--> statement-breakpoint
ALTER TABLE "login_codes" DROP CONSTRAINT "login_codes_phone_number_unique";--> statement-breakpoint
ALTER TABLE "login_codes" ADD COLUMN "challenge_id" varchar(64);--> statement-breakpoint
CREATE UNIQUE INDEX "login_codes_challenge_id_unique" ON "login_codes" USING btree ("challenge_id");--> statement-breakpoint
CREATE INDEX "login_codes_email_expires_idx" ON "login_codes" USING btree ("email","expires_at");--> statement-breakpoint
CREATE INDEX "login_codes_phone_expires_idx" ON "login_codes" USING btree ("phone_number","expires_at");