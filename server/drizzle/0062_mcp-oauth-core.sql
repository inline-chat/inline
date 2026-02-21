CREATE TABLE "oauth_access_tokens" (
	"token_hash" varchar(64) PRIMARY KEY NOT NULL,
	"grant_id" varchar(128) NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"revoked_at" timestamp (3)
);
--> statement-breakpoint
CREATE TABLE "oauth_auth_codes" (
	"code" varchar(256) PRIMARY KEY NOT NULL,
	"grant_id" varchar(128) NOT NULL,
	"client_id" varchar(128) NOT NULL,
	"redirect_uri" text NOT NULL,
	"code_challenge" text NOT NULL,
	"used_at" timestamp (3),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL
);
--> statement-breakpoint
CREATE TABLE "oauth_auth_requests" (
	"id" varchar(128) PRIMARY KEY NOT NULL,
	"client_id" varchar(128) NOT NULL,
	"redirect_uri" text NOT NULL,
	"state" text NOT NULL,
	"scope" text NOT NULL,
	"code_challenge" text NOT NULL,
	"csrf_token" text NOT NULL,
	"device_id" varchar(128) NOT NULL,
	"email" varchar(256),
	"challenge_token" varchar(128),
	"inline_user_id" integer,
	"inline_token_encrypted" "bytea",
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL
);
--> statement-breakpoint
CREATE TABLE "oauth_clients" (
	"client_id" varchar(128) PRIMARY KEY NOT NULL,
	"redirect_uris_json" text NOT NULL,
	"client_name" text,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "oauth_grants" (
	"id" varchar(128) PRIMARY KEY NOT NULL,
	"client_id" varchar(128) NOT NULL,
	"inline_user_id" integer NOT NULL,
	"scope" text NOT NULL,
	"space_ids_json" jsonb NOT NULL,
	"allow_dms" boolean DEFAULT false NOT NULL,
	"allow_home_threads" boolean DEFAULT false NOT NULL,
	"inline_token_encrypted" "bytea" NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"revoked_at" timestamp (3)
);
--> statement-breakpoint
CREATE TABLE "oauth_refresh_tokens" (
	"token_hash" varchar(64) PRIMARY KEY NOT NULL,
	"grant_id" varchar(128) NOT NULL,
	"replaced_by_hash" varchar(64),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"revoked_at" timestamp (3)
);
--> statement-breakpoint
ALTER TABLE "oauth_access_tokens" ADD CONSTRAINT "oauth_access_tokens_grant_id_oauth_grants_id_fk" FOREIGN KEY ("grant_id") REFERENCES "public"."oauth_grants"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_auth_codes" ADD CONSTRAINT "oauth_auth_codes_grant_id_oauth_grants_id_fk" FOREIGN KEY ("grant_id") REFERENCES "public"."oauth_grants"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_auth_codes" ADD CONSTRAINT "oauth_auth_codes_client_id_oauth_clients_client_id_fk" FOREIGN KEY ("client_id") REFERENCES "public"."oauth_clients"("client_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_auth_requests" ADD CONSTRAINT "oauth_auth_requests_client_id_oauth_clients_client_id_fk" FOREIGN KEY ("client_id") REFERENCES "public"."oauth_clients"("client_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_auth_requests" ADD CONSTRAINT "oauth_auth_requests_inline_user_id_users_id_fk" FOREIGN KEY ("inline_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_grants" ADD CONSTRAINT "oauth_grants_client_id_oauth_clients_client_id_fk" FOREIGN KEY ("client_id") REFERENCES "public"."oauth_clients"("client_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_grants" ADD CONSTRAINT "oauth_grants_inline_user_id_users_id_fk" FOREIGN KEY ("inline_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_refresh_tokens" ADD CONSTRAINT "oauth_refresh_tokens_grant_id_oauth_grants_id_fk" FOREIGN KEY ("grant_id") REFERENCES "public"."oauth_grants"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "oauth_access_tokens_grant_idx" ON "oauth_access_tokens" USING btree ("grant_id");--> statement-breakpoint
CREATE INDEX "oauth_access_tokens_expiry_idx" ON "oauth_access_tokens" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "oauth_auth_codes_expiry_idx" ON "oauth_auth_codes" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "oauth_auth_codes_grant_idx" ON "oauth_auth_codes" USING btree ("grant_id");--> statement-breakpoint
CREATE INDEX "oauth_auth_codes_used_idx" ON "oauth_auth_codes" USING btree ("used_at");--> statement-breakpoint
CREATE INDEX "oauth_auth_requests_expiry_idx" ON "oauth_auth_requests" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "oauth_auth_requests_client_idx" ON "oauth_auth_requests" USING btree ("client_id");--> statement-breakpoint
CREATE UNIQUE INDEX "oauth_auth_requests_challenge_unique" ON "oauth_auth_requests" USING btree ("challenge_token");--> statement-breakpoint
CREATE INDEX "oauth_clients_date_idx" ON "oauth_clients" USING btree ("date");--> statement-breakpoint
CREATE INDEX "oauth_grants_client_idx" ON "oauth_grants" USING btree ("client_id");--> statement-breakpoint
CREATE INDEX "oauth_grants_inline_user_idx" ON "oauth_grants" USING btree ("inline_user_id");--> statement-breakpoint
CREATE INDEX "oauth_grants_revoked_idx" ON "oauth_grants" USING btree ("revoked_at");--> statement-breakpoint
CREATE INDEX "oauth_refresh_tokens_grant_idx" ON "oauth_refresh_tokens" USING btree ("grant_id");--> statement-breakpoint
CREATE INDEX "oauth_refresh_tokens_expiry_idx" ON "oauth_refresh_tokens" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "oauth_refresh_tokens_revoked_idx" ON "oauth_refresh_tokens" USING btree ("revoked_at");