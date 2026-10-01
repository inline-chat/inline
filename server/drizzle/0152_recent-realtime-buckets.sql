CREATE TABLE "recent_realtime_buckets" (
	"bucket" integer NOT NULL,
	"entity_id" integer NOT NULL,
	"seq" integer NOT NULL,
	"expires_at" timestamp (3) with time zone NOT NULL,
	CONSTRAINT "recent_realtime_buckets_bucket_entity_id_pk" PRIMARY KEY("bucket","entity_id"),
	CONSTRAINT "recent_realtime_buckets_bucket_valid" CHECK ("recent_realtime_buckets"."bucket" in (1, 2, 3)),
	CONSTRAINT "recent_realtime_buckets_entity_positive" CHECK ("recent_realtime_buckets"."entity_id" > 0),
	CONSTRAINT "recent_realtime_buckets_seq_positive" CHECK ("recent_realtime_buckets"."seq" > 0)
);
--> statement-breakpoint
CREATE INDEX "recent_realtime_buckets_expiry_idx" ON "recent_realtime_buckets" USING btree ("expires_at");
--> statement-breakpoint
-- This short-lived index has frequent updates/deletes; reclaim its dead tuples
-- without changing vacuum settings for message history or the database.
ALTER TABLE "recent_realtime_buckets" SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_threshold = 100,
  autovacuum_analyze_scale_factor = 0.05,
  autovacuum_analyze_threshold = 100
);
