CREATE TYPE "public"."account_provider" AS ENUM('google', 'apple');--> statement-breakpoint
CREATE TYPE "public"."provider_auth_purpose" AS ENUM('app', 'mcp_oauth');--> statement-breakpoint
CREATE TYPE "public"."provider_auth_status" AS ENUM('pending_provider', 'pending_invite', 'pending_email', 'complete', 'used');--> statement-breakpoint
CREATE TABLE "account_identities" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"provider" "account_provider" NOT NULL,
	"subject_hash" varchar(64) NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "provider_auth_attempts" (
	"id" varchar(128) PRIMARY KEY NOT NULL,
	"provider" "account_provider" NOT NULL,
	"purpose" "provider_auth_purpose" NOT NULL,
	"status" "provider_auth_status" DEFAULT 'pending_provider' NOT NULL,
	"state_hash" varchar(64) NOT NULL,
	"nonce_hash" varchar(64) NOT NULL,
	"nonce_encrypted" "bytea" NOT NULL,
	"pkce_verifier_encrypted" "bytea",
	"continuation_hash" varchar(64),
	"subject_hash" varchar(64),
	"pending_profile_encrypted" "bytea",
	"confirmation_email" varchar(256),
	"challenge_token" varchar(128),
	"app_callback_scheme" varchar(64),
	"app_code_challenge" varchar(64),
	"oauth_auth_request_id" varchar(128),
	"client" jsonb NOT NULL,
	"inline_user_id" integer,
	"inline_token_encrypted" "bytea",
	"ticket_hash" varchar(64),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"used_at" timestamp (3)
);
--> statement-breakpoint
ALTER TABLE "account_identities" ADD CONSTRAINT "account_identities_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "provider_auth_attempts" ADD CONSTRAINT "provider_auth_attempts_oauth_request_fk" FOREIGN KEY ("oauth_auth_request_id") REFERENCES "public"."oauth_auth_requests"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "provider_auth_attempts" ADD CONSTRAINT "provider_auth_attempts_inline_user_id_users_id_fk" FOREIGN KEY ("inline_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "account_identities_provider_subject_unique" ON "account_identities" USING btree ("provider","subject_hash");--> statement-breakpoint
CREATE INDEX "account_identities_user_idx" ON "account_identities" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "provider_auth_attempts_state_unique" ON "provider_auth_attempts" USING btree ("state_hash");--> statement-breakpoint
CREATE UNIQUE INDEX "provider_auth_attempts_ticket_unique" ON "provider_auth_attempts" USING btree ("ticket_hash");--> statement-breakpoint
CREATE INDEX "provider_auth_attempts_expiry_idx" ON "provider_auth_attempts" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "provider_auth_attempts_oauth_request_idx" ON "provider_auth_attempts" USING btree ("oauth_auth_request_id");--> statement-breakpoint
CREATE INDEX "provider_auth_attempts_inline_user_idx" ON "provider_auth_attempts" USING btree ("inline_user_id");
