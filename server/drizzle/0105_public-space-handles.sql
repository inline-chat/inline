ALTER TABLE "spaces" DROP CONSTRAINT "spaces_handle_unique";--> statement-breakpoint
ALTER TABLE "spaces" ALTER COLUMN "handle" SET DATA TYPE varchar(256);--> statement-breakpoint
CREATE UNIQUE INDEX "spaces_handle_unique" ON "spaces" USING btree (lower("handle"));--> statement-breakpoint
UPDATE "spaces"
SET "handle" = 'townhall'
WHERE "id" = 16
  AND "name" = 'Town Hall'
  AND "is_public" = true
  AND "deleted" IS NULL
  AND "handle" IS NULL
  AND NOT EXISTS (
    SELECT 1
    FROM "spaces" AS "existing_space"
    WHERE lower("existing_space"."handle") = 'townhall'
  );
