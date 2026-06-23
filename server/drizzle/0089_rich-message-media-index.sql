CREATE TABLE "message_rich_media" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "message_rich_media_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"message_global_id" bigint NOT NULL,
	"chat_id" integer NOT NULL,
	"message_id" integer NOT NULL,
	"block_id" text NOT NULL,
	"block_path" text NOT NULL,
	"sort_order" integer NOT NULL,
	"kind" text NOT NULL,
	"status" text DEFAULT 'resolved' NOT NULL,
	"photo_id" bigint,
	"video_id" bigint,
	"document_id" bigint,
	"voice_id" bigint,
	"public_url_hash" "bytea",
	"public_url" "bytea",
	"public_url_iv" "bytea",
	"public_url_tag" "bytea",
	"error" text,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "message_rich_media" ADD CONSTRAINT "message_rich_media_message_global_id_messages_global_id_fk" FOREIGN KEY ("message_global_id") REFERENCES "public"."messages"("global_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_rich_media" ADD CONSTRAINT "message_rich_media_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_rich_media" ADD CONSTRAINT "message_rich_media_photo_id_photos_id_fk" FOREIGN KEY ("photo_id") REFERENCES "public"."photos"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_rich_media" ADD CONSTRAINT "message_rich_media_video_id_videos_id_fk" FOREIGN KEY ("video_id") REFERENCES "public"."videos"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_rich_media" ADD CONSTRAINT "message_rich_media_document_id_documents_id_fk" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_rich_media" ADD CONSTRAINT "message_rich_media_voice_id_voices_id_fk" FOREIGN KEY ("voice_id") REFERENCES "public"."voices"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "message_rich_media_message_idx" ON "message_rich_media" USING btree ("message_global_id","sort_order");--> statement-breakpoint
CREATE INDEX "message_rich_media_chat_message_idx" ON "message_rich_media" USING btree ("chat_id","message_id");--> statement-breakpoint
CREATE INDEX "message_rich_media_photo_idx" ON "message_rich_media" USING btree ("photo_id");--> statement-breakpoint
CREATE INDEX "message_rich_media_video_idx" ON "message_rich_media" USING btree ("video_id");--> statement-breakpoint
CREATE INDEX "message_rich_media_document_idx" ON "message_rich_media" USING btree ("document_id");--> statement-breakpoint
CREATE INDEX "message_rich_media_voice_idx" ON "message_rich_media" USING btree ("voice_id");--> statement-breakpoint
CREATE INDEX "message_rich_media_public_url_hash_idx" ON "message_rich_media" USING btree ("public_url_hash");