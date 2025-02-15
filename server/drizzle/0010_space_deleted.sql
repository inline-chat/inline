ALTER TABLE "spaces" ALTER COLUMN "date" SET DEFAULT now();--> statement-breakpoint
ALTER TABLE "spaces" ALTER COLUMN "date" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "spaces" ADD COLUMN "deleted" timestamp (3);