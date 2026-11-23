CREATE TABLE "data_task_items" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"task_id" text NOT NULL,
	"item_key" text NOT NULL,
	"tier" text NOT NULL,
	"plan_hash" text NOT NULL,
	"plan" jsonb NOT NULL,
	"before" jsonb NOT NULL,
	"after" jsonb NOT NULL,
	"applied_at" timestamp (3) DEFAULT now() NOT NULL,
	"reverted_at" timestamp (3)
);
--> statement-breakpoint
CREATE TABLE "data_task_runs" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"task_id" text NOT NULL,
	"status" text NOT NULL,
	"plan_hash" text,
	"items" integer DEFAULT 0 NOT NULL,
	"applied" integer DEFAULT 0 NOT NULL,
	"skipped" integer DEFAULT 0 NOT NULL,
	"reason" text,
	"source_commit" text,
	"started_at" timestamp (3) DEFAULT now() NOT NULL,
	"heartbeat_at" timestamp (3) DEFAULT now() NOT NULL,
	"finished_at" timestamp (3)
);
--> statement-breakpoint
CREATE UNIQUE INDEX "data_task_items_task_item_unique" ON "data_task_items" USING btree ("task_id","item_key");--> statement-breakpoint
CREATE INDEX "data_task_items_task_applied_idx" ON "data_task_items" USING btree ("task_id","applied_at");--> statement-breakpoint
CREATE UNIQUE INDEX "data_task_runs_one_running" ON "data_task_runs" USING btree ("task_id") WHERE "data_task_runs"."status" = 'running';--> statement-breakpoint
CREATE UNIQUE INDEX "data_task_runs_one_completed" ON "data_task_runs" USING btree ("task_id") WHERE "data_task_runs"."status" = 'completed';--> statement-breakpoint
CREATE INDEX "data_task_runs_task_started_idx" ON "data_task_runs" USING btree ("task_id","started_at");