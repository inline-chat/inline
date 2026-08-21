ALTER TYPE "public"."provider_auth_purpose" ADD VALUE IF NOT EXISTS 'hosted_login';--> statement-breakpoint
ALTER TABLE "oauth_auth_requests" ADD COLUMN "auth_method" varchar(16);--> statement-breakpoint
ALTER TABLE "oauth_grants" ALTER COLUMN "inline_token_encrypted" DROP NOT NULL;--> statement-breakpoint
CREATE TABLE "login_transactions" (
	"id" varchar(128) PRIMARY KEY NOT NULL,
	"capability_hash" "bytea" NOT NULL,
	"browser_csrf_hash" "bytea",
	"status" varchar(16) DEFAULT 'pending' NOT NULL,
	"target_kind" varchar(32) NOT NULL,
	"inline_protocol_auth_key_id" "bytea",
	"oauth_auth_request_id" varchar(128),
	"native_app_auth_request_id" varchar(128),
	"verification_code" varchar(12) NOT NULL,
	"pending_identifier" varchar(320),
	"challenge_token" varchar(128),
	"client" jsonb NOT NULL,
	"user_id" integer,
	"auth_method" varchar(16),
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"claimed_at" timestamp (3) with time zone,
	"completed_at" timestamp (3) with time zone,
	"cancelled_at" timestamp (3) with time zone,
	CONSTRAINT "login_transactions_capability_hash_length" CHECK (octet_length("login_transactions"."capability_hash") = 32),
	CONSTRAINT "login_transactions_browser_csrf_hash_length" CHECK ("login_transactions"."browser_csrf_hash" is null or octet_length("login_transactions"."browser_csrf_hash") = 32),
	CONSTRAINT "login_transactions_status_valid" CHECK ("login_transactions"."status" in ('pending', 'claimed', 'complete', 'cancelled')),
	CONSTRAINT "login_transactions_method_valid" CHECK ("login_transactions"."auth_method" is null or "login_transactions"."auth_method" in ('email', 'phone', 'google', 'apple')),
	CONSTRAINT "login_transactions_typed_target" CHECK ((
        ("login_transactions"."target_kind" = 'inline_protocol_key')::int +
        ("login_transactions"."target_kind" = 'oauth_authorization')::int +
        ("login_transactions"."target_kind" = 'native_app')::int
      ) = 1 and
      ("login_transactions"."inline_protocol_auth_key_id" is not null)::int +
      ("login_transactions"."oauth_auth_request_id" is not null)::int +
      ("login_transactions"."native_app_auth_request_id" is not null)::int = 1 and
      ("login_transactions"."target_kind" = 'inline_protocol_key') = ("login_transactions"."inline_protocol_auth_key_id" is not null) and
      ("login_transactions"."target_kind" = 'oauth_authorization') = ("login_transactions"."oauth_auth_request_id" is not null) and
      ("login_transactions"."target_kind" = 'native_app') = ("login_transactions"."native_app_auth_request_id" is not null)
      )
);
--> statement-breakpoint
CREATE TABLE "native_app_auth_requests" (
	"id" varchar(128) PRIMARY KEY NOT NULL,
	"callback_scheme" varchar(64) NOT NULL,
	"code_challenge" varchar(64) NOT NULL,
	"client" jsonb NOT NULL,
	"user_id" integer,
	"auth_method" varchar(16),
	"ticket_hash" "bytea",
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"proven_at" timestamp (3) with time zone,
	"redeemed_at" timestamp (3) with time zone,
	"cancelled_at" timestamp (3) with time zone,
	CONSTRAINT "native_app_auth_requests_method_valid" CHECK ("native_app_auth_requests"."auth_method" is null or "native_app_auth_requests"."auth_method" in ('email', 'phone', 'google', 'apple'))
);
--> statement-breakpoint
ALTER TABLE "provider_auth_attempts" ADD COLUMN "login_transaction_id" varchar(128);--> statement-breakpoint
ALTER TABLE "login_transactions" ADD CONSTRAINT "login_transactions_inline_protocol_auth_key_id_inline_protocol_auth_keys_auth_key_id_fk" FOREIGN KEY ("inline_protocol_auth_key_id") REFERENCES "public"."inline_protocol_auth_keys"("auth_key_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "login_transactions" ADD CONSTRAINT "login_transactions_oauth_auth_request_id_oauth_auth_requests_id_fk" FOREIGN KEY ("oauth_auth_request_id") REFERENCES "public"."oauth_auth_requests"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "login_transactions" ADD CONSTRAINT "login_transactions_native_app_auth_request_id_native_app_auth_requests_id_fk" FOREIGN KEY ("native_app_auth_request_id") REFERENCES "public"."native_app_auth_requests"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "login_transactions" ADD CONSTRAINT "login_transactions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "native_app_auth_requests" ADD CONSTRAINT "native_app_auth_requests_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "login_transactions_capability_unique" ON "login_transactions" USING btree ("capability_hash");--> statement-breakpoint
CREATE INDEX "login_transactions_expiry_idx" ON "login_transactions" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "login_transactions_user_idx" ON "login_transactions" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "login_transactions_inline_protocol_key_unique" ON "login_transactions" USING btree ("inline_protocol_auth_key_id") WHERE "login_transactions"."status" in ('pending', 'claimed');--> statement-breakpoint
CREATE UNIQUE INDEX "login_transactions_oauth_request_unique" ON "login_transactions" USING btree ("oauth_auth_request_id") WHERE "login_transactions"."status" in ('pending', 'claimed');--> statement-breakpoint
CREATE UNIQUE INDEX "login_transactions_native_app_request_unique" ON "login_transactions" USING btree ("native_app_auth_request_id") WHERE "login_transactions"."status" in ('pending', 'claimed');--> statement-breakpoint
CREATE INDEX "native_app_auth_requests_expiry_idx" ON "native_app_auth_requests" USING btree ("expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "native_app_auth_requests_ticket_unique" ON "native_app_auth_requests" USING btree ("ticket_hash");--> statement-breakpoint
ALTER TABLE "provider_auth_attempts" ADD CONSTRAINT "provider_auth_attempts_login_transaction_fk" FOREIGN KEY ("login_transaction_id") REFERENCES "public"."login_transactions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "provider_auth_attempts_login_transaction_idx" ON "provider_auth_attempts" USING btree ("login_transaction_id");
