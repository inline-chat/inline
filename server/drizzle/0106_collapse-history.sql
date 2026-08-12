-- Archived pre-v0.1 migrations may already have created this column and their legacy constraints.
ALTER TABLE "dialogs" ADD COLUMN IF NOT EXISTS "collapsed_max_id" integer;--> statement-breakpoint
ALTER TABLE "dialogs" DROP CONSTRAINT IF EXISTS "dialogs_collapse_pair_check";--> statement-breakpoint
ALTER TABLE "dialogs" DROP CONSTRAINT IF EXISTS "dialogs_collapsed_max_id_positive";
