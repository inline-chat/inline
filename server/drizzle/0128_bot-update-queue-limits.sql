ALTER TABLE "bot_update_streams" ADD COLUMN "config_generation" bigint DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE "bot_update_streams" ADD COLUMN "pending_update_count" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "bot_update_streams" ADD COLUMN "pending_payload_bytes" bigint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "bot_updates" ADD COLUMN "payload_byte_count" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "bot_updates" ADD COLUMN "claim_token" varchar(64);--> statement-breakpoint
ALTER TABLE "bot_updates" ADD COLUMN "claim_generation" bigint;--> statement-breakpoint
ALTER TABLE "bot_updates" ADD COLUMN "claim_expires_at" timestamp (3);--> statement-breakpoint
ALTER TABLE "bot_updates" ADD COLUMN "next_attempt_at" timestamp (3) DEFAULT now() NOT NULL;--> statement-breakpoint
ALTER TABLE "bot_updates" ADD COLUMN "attempt_count" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
UPDATE "bot_updates"
SET "payload_byte_count" = octet_length("payload_encrypted");--> statement-breakpoint
WITH "pending" AS (
	SELECT
		"updates"."bot_user_id",
		count(*)::integer AS "pending_update_count",
		coalesce(sum("updates"."payload_byte_count"), 0)::bigint AS "pending_payload_bytes"
	FROM "bot_updates" AS "updates"
	INNER JOIN "bot_update_streams" AS "streams"
		ON "streams"."bot_user_id" = "updates"."bot_user_id"
	WHERE "updates"."update_id" > "streams"."acknowledged_update_id"
		AND "updates"."expires_at" > now()
	GROUP BY "updates"."bot_user_id"
)
UPDATE "bot_update_streams" AS "streams"
SET
	"pending_update_count" = "pending"."pending_update_count",
	"pending_payload_bytes" = "pending"."pending_payload_bytes"
FROM "pending"
WHERE "streams"."bot_user_id" = "pending"."bot_user_id";--> statement-breakpoint
CREATE INDEX "bot_updates_delivery_idx" ON "bot_updates" USING btree ("next_attempt_at","claim_expires_at","expires_at","bot_user_id","update_id");
