CREATE TABLE "inline_protocol_auth_keys" (
	"auth_key_id" "bytea" PRIMARY KEY NOT NULL,
	"auth_key_encrypted" "bytea" NOT NULL,
	"key_encryption_key_id" varchar(32) NOT NULL,
	"current_server_salt" bigint NOT NULL,
	"previous_server_salt" bigint,
	"server_salt_updated_at" timestamp (3) DEFAULT now() NOT NULL,
	"user_id" integer,
	"account_session_id" integer,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"authorized_at" timestamp (3),
	"last_used_at" timestamp (3),
	"expires_at" timestamp (3),
	"revoked_at" timestamp (3),
	CONSTRAINT "inline_protocol_auth_keys_id_length" CHECK (octet_length("inline_protocol_auth_keys"."auth_key_id") = 8),
	CONSTRAINT "inline_protocol_auth_keys_encrypted_length" CHECK (octet_length("inline_protocol_auth_keys"."auth_key_encrypted") = 284)
);
--> statement-breakpoint
CREATE TABLE "inline_protocol_requests" (
	"auth_key_id" "bytea" NOT NULL,
	"protocol_session_id" bigint NOT NULL,
	"message_id" bigint NOT NULL,
	"request_digest" "bytea" NOT NULL,
	"result_body" "bytea",
	"claimed_at" timestamp (3) DEFAULT now() NOT NULL,
	"completed_at" timestamp (3),
	"expires_at" timestamp (3) NOT NULL,
	CONSTRAINT "inline_protocol_requests_pk" PRIMARY KEY("auth_key_id","protocol_session_id","message_id"),
	CONSTRAINT "inline_protocol_requests_key_id_length" CHECK (octet_length("inline_protocol_requests"."auth_key_id") = 8),
	CONSTRAINT "inline_protocol_requests_digest_length" CHECK (octet_length("inline_protocol_requests"."request_digest") = 32),
	CONSTRAINT "inline_protocol_requests_result_length" CHECK ("inline_protocol_requests"."result_body" is null or octet_length("inline_protocol_requests"."result_body") <= 16777216)
);
--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ADD CONSTRAINT "inline_protocol_auth_keys_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_keys" ADD CONSTRAINT "inline_protocol_auth_keys_account_session_id_sessions_id_fk" FOREIGN KEY ("account_session_id") REFERENCES "public"."sessions"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" ADD CONSTRAINT "inline_protocol_requests_auth_key_id_inline_protocol_auth_keys_auth_key_id_fk" FOREIGN KEY ("auth_key_id") REFERENCES "public"."inline_protocol_auth_keys"("auth_key_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "inline_protocol_auth_keys_user_idx" ON "inline_protocol_auth_keys" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "inline_protocol_auth_keys_session_idx" ON "inline_protocol_auth_keys" USING btree ("account_session_id");--> statement-breakpoint
CREATE INDEX "inline_protocol_auth_keys_expiry_idx" ON "inline_protocol_auth_keys" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "inline_protocol_requests_expiry_idx" ON "inline_protocol_requests" USING btree ("expires_at");
