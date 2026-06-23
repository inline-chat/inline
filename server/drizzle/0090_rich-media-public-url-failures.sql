CREATE TABLE "rich_media_public_url_failures" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "rich_media_public_url_failures_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"kind" text NOT NULL,
	"url_hash" "bytea" NOT NULL,
	"url_host" text,
	"failure_count" integer DEFAULT 1 NOT NULL,
	"last_error" text,
	"last_failed_at" timestamp (3) DEFAULT now() NOT NULL,
	"retry_after" timestamp (3) NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "rich_media_public_url_failures_kind_url_hash_unique" ON "rich_media_public_url_failures" USING btree ("kind","url_hash");--> statement-breakpoint
CREATE INDEX "rich_media_public_url_failures_retry_after_idx" ON "rich_media_public_url_failures" USING btree ("retry_after");--> statement-breakpoint
CREATE INDEX "rich_media_public_url_failures_url_host_idx" ON "rich_media_public_url_failures" USING btree ("url_host");