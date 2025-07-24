CREATE TABLE "updates" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "updates_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"bucket" integer NOT NULL,
	"entity_id" integer NOT NULL,
	"seq" integer NOT NULL,
	"payload" "bytea" NOT NULL,
	CONSTRAINT "updates_unique" UNIQUE("bucket","entity_id","seq")
);
--> statement-breakpoint
ALTER TABLE "spaces" ADD COLUMN "update_seq" integer DEFAULT 0;--> statement-breakpoint
ALTER TABLE "spaces" ADD COLUMN "last_update_date" timestamp (3);--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "update_seq" integer DEFAULT 0;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "last_update_date" timestamp (3);--> statement-breakpoint
CREATE INDEX "updates_bucket_idx" ON "updates" USING btree ("bucket","entity_id","seq");--> statement-breakpoint
CREATE INDEX "updates_date_idx" ON "updates" USING btree ("date");