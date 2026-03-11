CREATE TABLE "voices" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "voices_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"file_id" integer,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"duration" integer,
	"waveform" "bytea"
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "voice_id" bigint;--> statement-breakpoint
ALTER TABLE "voices" ADD CONSTRAINT "voices_file_id_files_id_fk" FOREIGN KEY ("file_id") REFERENCES "public"."files"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_voice_id_voices_id_fk" FOREIGN KEY ("voice_id") REFERENCES "public"."voices"("id") ON DELETE no action ON UPDATE no action;