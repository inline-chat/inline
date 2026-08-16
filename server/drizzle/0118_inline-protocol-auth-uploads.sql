CREATE TABLE "inline_protocol_auth_challenges" (
	"challenge_id" "bytea" PRIMARY KEY NOT NULL,
	"auth_key_id" "bytea" NOT NULL,
	"identifier_encrypted" "bytea" NOT NULL,
	"identifier_hash" "bytea" NOT NULL,
	"code_mac" "bytea" NOT NULL,
	"pepper_key_id" varchar(32) NOT NULL,
	"delivery" varchar(16) NOT NULL,
	"client" jsonb NOT NULL,
	"network_hash" "bytea",
	"device_hash" "bytea",
	"attempts" smallint DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"consumed_at" timestamp (3),
	CONSTRAINT "inline_protocol_auth_challenges_id_length" CHECK (octet_length("inline_protocol_auth_challenges"."challenge_id") = 32),
	CONSTRAINT "inline_protocol_auth_challenges_key_id_length" CHECK (octet_length("inline_protocol_auth_challenges"."auth_key_id") = 8),
	CONSTRAINT "inline_protocol_auth_challenges_identifier_hash_length" CHECK (octet_length("inline_protocol_auth_challenges"."identifier_hash") = 32),
	CONSTRAINT "inline_protocol_auth_challenges_code_mac_length" CHECK (octet_length("inline_protocol_auth_challenges"."code_mac") = 32)
);
--> statement-breakpoint
CREATE TABLE "inline_protocol_uploads" (
	"upload_id" "bytea" PRIMARY KEY NOT NULL,
	"capability_hash" "bytea" NOT NULL,
	"permanent_auth_key_id" "bytea" NOT NULL,
	"issuing_temporary_auth_key_id" "bytea" NOT NULL,
	"user_id" integer NOT NULL,
	"account_session_id" integer NOT NULL,
	"file_name" text NOT NULL,
	"mime_type" varchar(255) NOT NULL,
	"byte_count" bigint NOT NULL,
	"sha256" "bytea" NOT NULL,
	"kind" varchar(16) NOT NULL,
	"status" varchar(16) DEFAULT 'pending' NOT NULL,
	"lock_token" "bytea",
	"locked_at" timestamp (3),
	"file_unique_id" varchar(128),
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL,
	"completed_at" timestamp (3),
	CONSTRAINT "inline_protocol_uploads_id_length" CHECK (octet_length("inline_protocol_uploads"."upload_id") = 16),
	CONSTRAINT "inline_protocol_uploads_capability_hash_length" CHECK (octet_length("inline_protocol_uploads"."capability_hash") = 32),
	CONSTRAINT "inline_protocol_uploads_permanent_key_length" CHECK (octet_length("inline_protocol_uploads"."permanent_auth_key_id") = 8),
	CONSTRAINT "inline_protocol_uploads_temporary_key_length" CHECK (octet_length("inline_protocol_uploads"."issuing_temporary_auth_key_id") = 8),
	CONSTRAINT "inline_protocol_uploads_sha_length" CHECK (octet_length("inline_protocol_uploads"."sha256") = 32),
	CONSTRAINT "inline_protocol_uploads_byte_count_positive" CHECK ("inline_protocol_uploads"."byte_count" > 0),
	CONSTRAINT "inline_protocol_uploads_status_valid" CHECK ("inline_protocol_uploads"."status" in ('pending', 'uploading', 'complete', 'failed'))
);
--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" DROP CONSTRAINT "inline_protocol_requests_auth_key_id_inline_protocol_auth_keys_auth_key_id_fk";
--> statement-breakpoint
ALTER TABLE "inline_protocol_auth_challenges" ADD CONSTRAINT "inline_protocol_auth_challenges_auth_key_id_inline_protocol_auth_keys_auth_key_id_fk" FOREIGN KEY ("auth_key_id") REFERENCES "public"."inline_protocol_auth_keys"("auth_key_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ADD CONSTRAINT "inline_protocol_uploads_permanent_auth_key_id_inline_protocol_auth_keys_auth_key_id_fk" FOREIGN KEY ("permanent_auth_key_id") REFERENCES "public"."inline_protocol_auth_keys"("auth_key_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ADD CONSTRAINT "inline_protocol_uploads_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_protocol_uploads" ADD CONSTRAINT "inline_protocol_uploads_account_session_id_sessions_id_fk" FOREIGN KEY ("account_session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "inline_protocol_auth_challenges_key_created_idx" ON "inline_protocol_auth_challenges" USING btree ("auth_key_id","created_at");--> statement-breakpoint
CREATE INDEX "inline_protocol_auth_challenges_identifier_created_idx" ON "inline_protocol_auth_challenges" USING btree ("identifier_hash","created_at");--> statement-breakpoint
CREATE INDEX "inline_protocol_auth_challenges_expiry_idx" ON "inline_protocol_auth_challenges" USING btree ("expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "inline_protocol_uploads_capability_unique" ON "inline_protocol_uploads" USING btree ("capability_hash");--> statement-breakpoint
CREATE INDEX "inline_protocol_uploads_session_idx" ON "inline_protocol_uploads" USING btree ("account_session_id","created_at");--> statement-breakpoint
CREATE INDEX "inline_protocol_uploads_expiry_idx" ON "inline_protocol_uploads" USING btree ("expires_at");
