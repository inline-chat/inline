ALTER TABLE "users" ADD COLUMN "next_thread_number" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE "spaces" ADD COLUMN "next_thread_number" integer DEFAULT 1 NOT NULL;--> statement-breakpoint

WITH ranked_user_threads AS (
	SELECT
		"id",
		row_number() OVER (
			PARTITION BY "created_by"
			ORDER BY "date" ASC NULLS FIRST, "id" ASC
		)::integer AS "scope_number"
	FROM "chats"
	WHERE "type" = 'thread'
		AND "space_id" IS NULL
		AND "created_by" IS NOT NULL
)
UPDATE "chats"
SET "thread_number" = ranked_user_threads."scope_number"
FROM ranked_user_threads
WHERE "chats"."id" = ranked_user_threads."id";--> statement-breakpoint

UPDATE "users"
SET "next_thread_number" = user_maxima."next_thread_number"
FROM (
	SELECT "created_by", coalesce(max("thread_number"), 0) + 1 AS "next_thread_number"
	FROM "chats"
	WHERE "type" = 'thread'
		AND "space_id" IS NULL
		AND "created_by" IS NOT NULL
	GROUP BY "created_by"
) AS user_maxima
WHERE "users"."id" = user_maxima."created_by";--> statement-breakpoint

UPDATE "spaces"
SET "next_thread_number" = space_maxima."next_thread_number"
FROM (
	SELECT "space_id", coalesce(max("thread_number"), 0) + 1 AS "next_thread_number"
	FROM "chats"
	WHERE "type" = 'thread'
		AND "space_id" IS NOT NULL
	GROUP BY "space_id"
) AS space_maxima
WHERE "spaces"."id" = space_maxima."space_id";--> statement-breakpoint

CREATE UNIQUE INDEX "user_thread_number_unique" ON "chats" USING btree ("created_by","thread_number") WHERE "chats"."space_id" is null and "chats"."thread_number" is not null;
