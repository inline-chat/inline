CREATE TABLE "block_content_image_jobs" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "block_content_image_jobs_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"content_id" bigint NOT NULL,
	"expected_revision" integer NOT NULL,
	"block_path" integer[] NOT NULL,
	"source_hash" "bytea" NOT NULL,
	"source_encrypted" "bytea" NOT NULL,
	"source_iv" "bytea" NOT NULL,
	"source_tag" "bytea" NOT NULL,
	"state" varchar(16) DEFAULT 'pending' NOT NULL,
	"attempts" smallint DEFAULT 0 NOT NULL,
	"available_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"lease_token" varchar(64),
	"lease_until" timestamp (3) with time zone,
	"staged_object_path_encrypted" "bytea",
	"staged_object_path_iv" "bytea",
	"staged_object_path_tag" "bytea",
	"photo_id" bigint,
	"last_error_code" varchar(64),
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "block_content_image_jobs_state_check" CHECK ("block_content_image_jobs"."state" in ('pending', 'processing', 'ready', 'failed', 'canceled')),
	CONSTRAINT "block_content_image_jobs_attempts_check" CHECK ("block_content_image_jobs"."attempts" >= 0)
);
--> statement-breakpoint
CREATE TABLE "block_contents" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "block_contents_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"payload_encrypted" "bytea" NOT NULL,
	"payload_iv" "bytea" NOT NULL,
	"payload_tag" "bytea" NOT NULL,
	"schema_version" smallint DEFAULT 1 NOT NULL,
	"revision" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "block_content_id" bigint;--> statement-breakpoint
ALTER TABLE "block_content_image_jobs" ADD CONSTRAINT "block_content_image_jobs_content_id_block_contents_id_fk" FOREIGN KEY ("content_id") REFERENCES "public"."block_contents"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "block_content_image_jobs" ADD CONSTRAINT "block_content_image_jobs_photo_id_photos_id_fk" FOREIGN KEY ("photo_id") REFERENCES "public"."photos"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "block_content_image_jobs_ready_idx" ON "block_content_image_jobs" USING btree ("state","available_at","id");--> statement-breakpoint
CREATE INDEX "block_content_image_jobs_revision_idx" ON "block_content_image_jobs" USING btree ("content_id","expected_revision");--> statement-breakpoint
CREATE INDEX "block_content_image_jobs_path_idx" ON "block_content_image_jobs" USING btree ("content_id","block_path");--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_block_content_id_block_contents_id_fk" FOREIGN KEY ("block_content_id") REFERENCES "public"."block_contents"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "messages_block_content_id_idx" ON "messages" USING btree ("block_content_id");
