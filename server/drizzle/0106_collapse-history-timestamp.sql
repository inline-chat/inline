ALTER TABLE "dialogs" ADD COLUMN "collapsed_at" timestamp (3) with time zone;--> statement-breakpoint
UPDATE "dialogs" SET "collapsed_at" = NOW() WHERE "collapsed_max_id" IS NOT NULL;--> statement-breakpoint
ALTER TABLE "dialogs" ADD CONSTRAINT "dialogs_collapse_pair_check" CHECK (("dialogs"."collapsed_max_id" IS NULL) = ("dialogs"."collapsed_at" IS NULL));
