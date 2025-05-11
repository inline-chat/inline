CREATE TABLE IF NOT EXISTS "message_translations" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "message_translations_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"message_id" bigint NOT NULL,
	"chat_id" bigint NOT NULL,
	"translation" "bytea",
	"translation_iv" "bytea",
	"translation_tag" "bytea",
	"language" text NOT NULL
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "message_translations" ADD CONSTRAINT "message_translations_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "message_translations" ADD CONSTRAINT "chat_id_message_id_fk" FOREIGN KEY ("chat_id","message_id") REFERENCES "public"."messages"("chat_id","message_id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
