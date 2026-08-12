ALTER TABLE "integrations" ALTER COLUMN "date" SET DATA TYPE timestamp (3) with time zone USING "date" AT TIME ZONE current_setting('TimeZone');--> statement-breakpoint
ALTER TABLE "integrations" ALTER COLUMN "date" SET DEFAULT now();
