WITH "space_thread_maxima" AS (
	SELECT "space_id", max("thread_number") AS "max_thread_number"
	FROM "chats"
	WHERE "space_id" IS NOT NULL
		AND "thread_number" IS NOT NULL
	GROUP BY "space_id"
)
UPDATE "spaces"
SET "next_thread_number" = greatest(
	"spaces"."next_thread_number",
	"space_thread_maxima"."max_thread_number" + 1
)
FROM "space_thread_maxima"
WHERE "spaces"."id" = "space_thread_maxima"."space_id"
	AND "spaces"."next_thread_number" <= "space_thread_maxima"."max_thread_number";
