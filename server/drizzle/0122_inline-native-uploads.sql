CREATE TABLE "inline_upload_parts" (
	"upload_id" bigint NOT NULL,
	"part_index" integer NOT NULL,
	"byte_count" integer NOT NULL,
	"sha256" "bytea" NOT NULL,
	"object_key" text NOT NULL,
	"accepted_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "inline_upload_parts_pk" PRIMARY KEY("upload_id","part_index"),
	CONSTRAINT "inline_upload_parts_index_valid" CHECK ("inline_upload_parts"."part_index" >= 0),
	CONSTRAINT "inline_upload_parts_byte_count_valid" CHECK ("inline_upload_parts"."byte_count" between 1 and 524288),
	CONSTRAINT "inline_upload_parts_sha_length" CHECK (octet_length("inline_upload_parts"."sha256") = 32)
);
--> statement-breakpoint
CREATE TABLE "inline_uploads" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "inline_uploads_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"upload_id" "bytea" NOT NULL,
	"client_upload_id" "bytea" NOT NULL,
	"permanent_auth_key_id" "bytea" NOT NULL,
	"user_id" integer NOT NULL,
	"account_session_id" integer NOT NULL,
	"file_name" text NOT NULL,
	"mime_type" varchar(255) NOT NULL,
	"byte_count" bigint NOT NULL,
	"sha256" "bytea" NOT NULL,
	"kind" varchar(16) NOT NULL,
	"thumbnail_file_unique_id" varchar(128),
	"video_width" integer,
	"video_height" integer,
	"duration" integer,
	"is_animated" boolean,
	"has_audio" boolean,
	"waveform" "bytea",
	"part_size" integer NOT NULL,
	"part_count" integer NOT NULL,
	"status" varchar(16) DEFAULT 'uploading' NOT NULL,
	"failure_code" varchar(32),
	"failure_retryable" boolean,
	"lock_token" "bytea",
	"locked_at" timestamp (3) with time zone,
	"result_file_unique_id" varchar(128),
	"result_media_id" bigint,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"last_part_at" timestamp (3) with time zone,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"hard_expires_at" timestamp (3) with time zone NOT NULL,
	"completed_at" timestamp (3) with time zone,
	"canceled_at" timestamp (3) with time zone,
	CONSTRAINT "inline_uploads_id_length" CHECK (octet_length("inline_uploads"."upload_id") = 16),
	CONSTRAINT "inline_uploads_client_id_length" CHECK (octet_length("inline_uploads"."client_upload_id") = 16),
	CONSTRAINT "inline_uploads_permanent_key_length" CHECK (octet_length("inline_uploads"."permanent_auth_key_id") = 8),
	CONSTRAINT "inline_uploads_sha_length" CHECK (octet_length("inline_uploads"."sha256") = 32),
	CONSTRAINT "inline_uploads_byte_count_positive" CHECK ("inline_uploads"."byte_count" > 0),
	CONSTRAINT "inline_uploads_part_size_valid" CHECK ("inline_uploads"."part_size" = 524288),
	CONSTRAINT "inline_uploads_part_count_valid" CHECK ("inline_uploads"."part_count" between 1 and 1000),
	CONSTRAINT "inline_uploads_kind_valid" CHECK ("inline_uploads"."kind" in ('photo', 'video', 'document', 'voice')),
	CONSTRAINT "inline_uploads_status_valid" CHECK ("inline_uploads"."status" in ('uploading', 'processing', 'complete', 'failed', 'canceled'))
);
--> statement-breakpoint
ALTER TABLE "inline_upload_parts" ADD CONSTRAINT "inline_upload_parts_upload_id_inline_uploads_id_fk" FOREIGN KEY ("upload_id") REFERENCES "public"."inline_uploads"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD CONSTRAINT "inline_uploads_permanent_auth_key_id_inline_protocol_auth_keys_auth_key_id_fk" FOREIGN KEY ("permanent_auth_key_id") REFERENCES "public"."inline_protocol_auth_keys"("auth_key_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD CONSTRAINT "inline_uploads_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "inline_uploads" ADD CONSTRAINT "inline_uploads_account_session_id_sessions_id_fk" FOREIGN KEY ("account_session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "inline_uploads_upload_id_unique" ON "inline_uploads" USING btree ("upload_id");--> statement-breakpoint
CREATE UNIQUE INDEX "inline_uploads_session_client_id_unique" ON "inline_uploads" USING btree ("account_session_id","client_upload_id");--> statement-breakpoint
CREATE INDEX "inline_uploads_permanent_key_idx" ON "inline_uploads" USING btree ("permanent_auth_key_id");--> statement-breakpoint
CREATE INDEX "inline_uploads_user_status_idx" ON "inline_uploads" USING btree ("user_id","status");--> statement-breakpoint
CREATE INDEX "inline_uploads_session_created_idx" ON "inline_uploads" USING btree ("account_session_id","created_at");--> statement-breakpoint
CREATE INDEX "inline_uploads_expiry_idx" ON "inline_uploads" USING btree ("status","expires_at");