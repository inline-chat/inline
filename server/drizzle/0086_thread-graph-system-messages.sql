CREATE TYPE "public"."thread_graph_link_kind" AS ENUM('thread_link', 'reply_thread');--> statement-breakpoint
CREATE TYPE "public"."thread_graph_scope_type" AS ENUM('user', 'space');--> statement-breakpoint
CREATE TABLE "thread_graph_links" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"dedupe_key" varchar(255) NOT NULL,
	"kind" "thread_graph_link_kind" NOT NULL,
	"scope_type" "thread_graph_scope_type" NOT NULL,
	"scope_id" integer NOT NULL,
	"from_chat_id" integer NOT NULL,
	"from_message_global_id" bigint,
	"from_message_id" integer,
	"from_message_revision" integer,
	"entity_index" integer,
	"to_chat_id" integer NOT NULL,
	"backlink_message_global_id" bigint,
	"link_text_hmac" "bytea",
	"target_title_hmac" "bytea",
	"deleted_at" timestamp (3),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "thread_graph_links_dedupe_key_unique" UNIQUE("dedupe_key")
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "system_message_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "system_message_iv" "bytea";--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "system_message_tag" "bytea";--> statement-breakpoint
ALTER TABLE "thread_graph_links" ADD CONSTRAINT "tgl_from_chat_fk" FOREIGN KEY ("from_chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "thread_graph_links" ADD CONSTRAINT "tgl_from_message_fk" FOREIGN KEY ("from_message_global_id") REFERENCES "public"."messages"("global_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "thread_graph_links" ADD CONSTRAINT "tgl_to_chat_fk" FOREIGN KEY ("to_chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "thread_graph_links" ADD CONSTRAINT "tgl_backlink_message_fk" FOREIGN KEY ("backlink_message_global_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "thread_graph_links_scope_to_chat_idx" ON "thread_graph_links" USING btree ("scope_type","scope_id","to_chat_id");--> statement-breakpoint
CREATE INDEX "thread_graph_links_scope_from_chat_idx" ON "thread_graph_links" USING btree ("scope_type","scope_id","from_chat_id");--> statement-breakpoint
CREATE INDEX "thread_graph_links_from_message_idx" ON "thread_graph_links" USING btree ("from_message_global_id");--> statement-breakpoint
CREATE INDEX "thread_graph_links_backlink_message_idx" ON "thread_graph_links" USING btree ("backlink_message_global_id");--> statement-breakpoint
CREATE INDEX "thread_graph_links_active_idx" ON "thread_graph_links" USING btree ("kind","to_chat_id") WHERE "thread_graph_links"."deleted_at" is null;
