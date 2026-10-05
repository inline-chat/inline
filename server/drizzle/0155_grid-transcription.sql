CREATE TABLE "grid_transcription_runs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"source_room_id" integer NOT NULL,
	"space_id" integer NOT NULL,
	"room_chat_id" integer NOT NULL,
	"transcript_chat_id" integer NOT NULL,
	"destination_parent_chat_id" integer NOT NULL,
	"original_anchor_id" integer NOT NULL,
	"room_link_message_id" integer,
	"actor_user_id" integer NOT NULL,
	"request_id" uuid NOT NULL,
	"model" varchar(32) NOT NULL,
	"state" varchar(16) NOT NULL,
	"generation" integer NOT NULL,
	"provider_target" varchar(255) NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	"claim_epoch" integer DEFAULT 0 NOT NULL,
	"worker_id" varchar(80),
	"lease_expires_at" timestamp (3),
	"expires_at" timestamp (3) NOT NULL,
	"stop_requested_at" timestamp (3),
	"interruption_reason" varchar(80),
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "grid_transcription_state_check" CHECK ("grid_transcription_runs"."state" in ('starting','active','stopping','stopped','interrupted'))
);
--> statement-breakpoint
CREATE TABLE "grid_transcription_segments" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"run_id" uuid NOT NULL,
	"claim_epoch" integer NOT NULL,
	"speaker_user_id" integer NOT NULL,
	"membership_id" uuid NOT NULL,
	"track_sid" varchar(128) NOT NULL,
	"source_turn_key" varchar(128) NOT NULL,
	"state" varchar(16) DEFAULT 'admitted' NOT NULL,
	"message_id" integer,
	"admitted_at" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "grid_transcription_segment_state_check" CHECK ("grid_transcription_segments"."state" in ('admitted','finalized','discarded'))
);
--> statement-breakpoint
CREATE TABLE "grid_transcription_space_revisions" (
	"space_id" integer PRIMARY KEY NOT NULL,
	"revision" bigint DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE TABLE "grid_transcription_worker" (
	"id" integer PRIMARY KEY NOT NULL,
	"worker_id" varchar(80) NOT NULL,
	"model" varchar(32) NOT NULL,
	"heartbeat_at" timestamp (3) NOT NULL
);
--> statement-breakpoint
ALTER TABLE "grid_rooms" ADD COLUMN "room_thread_id" integer;--> statement-breakpoint
ALTER TABLE "grid_transcription_segments" ADD CONSTRAINT "grid_transcription_segments_run_id_grid_transcription_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."grid_transcription_runs"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "grid_transcription_request_unique" ON "grid_transcription_runs" USING btree ("actor_user_id","request_id");--> statement-breakpoint
CREATE UNIQUE INDEX "grid_transcription_active_room_unique" ON "grid_transcription_runs" USING btree ("source_room_id") WHERE "grid_transcription_runs"."state" in ('starting','active','stopping');--> statement-breakpoint
CREATE UNIQUE INDEX "grid_transcription_active_destination_unique" ON "grid_transcription_runs" USING btree ("transcript_chat_id") WHERE "grid_transcription_runs"."state" in ('starting','active','stopping');--> statement-breakpoint
CREATE INDEX "grid_transcription_space_recent_idx" ON "grid_transcription_runs" USING btree ("space_id","created_at");--> statement-breakpoint
CREATE INDEX "grid_transcription_source_room_idx" ON "grid_transcription_runs" USING btree ("source_room_id");--> statement-breakpoint
CREATE UNIQUE INDEX "grid_transcription_segment_source_unique" ON "grid_transcription_segments" USING btree ("run_id","track_sid","source_turn_key");--> statement-breakpoint
CREATE FUNCTION "bump_grid_transcription_revision"() RETURNS trigger AS $$
BEGIN
  INSERT INTO "grid_transcription_space_revisions" ("space_id", "revision") VALUES (NEW."space_id", 1)
  ON CONFLICT ("space_id") DO UPDATE
  SET "revision" = "grid_transcription_space_revisions"."revision" + 1;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint
CREATE TRIGGER "grid_transcription_revision_changed"
AFTER INSERT OR UPDATE OF "state", "revision" ON "grid_transcription_runs"
FOR EACH ROW EXECUTE FUNCTION "bump_grid_transcription_revision"();
