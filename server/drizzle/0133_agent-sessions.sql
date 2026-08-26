CREATE TABLE "agent_session_messages" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"agent_session_id" bigint NOT NULL,
	"source_key_hash" "bytea" NOT NULL,
	"item_key_hash" "bytea",
	"source_ref_encrypted" "bytea" NOT NULL,
	"revision_ref_encrypted" "bytea",
	"message_global_id" bigint,
	"relation" smallint NOT NULL,
	"role" smallint NOT NULL,
	"complete" boolean DEFAULT false NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "agent_sessions" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"chat_id" integer NOT NULL,
	"bot_user_id" integer NOT NULL,
	"owner_user_id" integer NOT NULL,
	"provider" smallint NOT NULL,
	"session_key_hash" "bytea" NOT NULL,
	"instance_ref_encrypted" "bytea" NOT NULL,
	"session_ref_encrypted" "bytea" NOT NULL,
	"project_ref_encrypted" "bytea",
	"status_message_global_id" bigint,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "counts_as_unread" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_session_messages" ADD CONSTRAINT "agent_session_messages_agent_session_id_agent_sessions_id_fk" FOREIGN KEY ("agent_session_id") REFERENCES "public"."agent_sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_session_messages" ADD CONSTRAINT "agent_session_messages_message_global_id_messages_global_id_fk" FOREIGN KEY ("message_global_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD CONSTRAINT "agent_sessions_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD CONSTRAINT "agent_sessions_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD CONSTRAINT "agent_sessions_owner_user_id_users_id_fk" FOREIGN KEY ("owner_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD CONSTRAINT "agent_sessions_status_message_global_id_messages_global_id_fk" FOREIGN KEY ("status_message_global_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "agent_session_messages_source_unique" ON "agent_session_messages" USING btree ("agent_session_id","source_key_hash");--> statement-breakpoint
CREATE UNIQUE INDEX "agent_session_messages_item_unique" ON "agent_session_messages" USING btree ("agent_session_id","item_key_hash") WHERE "agent_session_messages"."item_key_hash" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "agent_session_messages_message_unique" ON "agent_session_messages" USING btree ("agent_session_id","message_global_id") WHERE "agent_session_messages"."message_global_id" is not null;--> statement-breakpoint
CREATE INDEX "agent_session_messages_session_idx" ON "agent_session_messages" USING btree ("agent_session_id");--> statement-breakpoint
CREATE UNIQUE INDEX "agent_sessions_external_unique" ON "agent_sessions" USING btree ("bot_user_id","provider","session_key_hash");--> statement-breakpoint
CREATE UNIQUE INDEX "agent_sessions_chat_bot_unique" ON "agent_sessions" USING btree ("chat_id","bot_user_id");--> statement-breakpoint
CREATE INDEX "agent_sessions_owner_idx" ON "agent_sessions" USING btree ("owner_user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "agent_sessions_status_message_unique" ON "agent_sessions" USING btree ("status_message_global_id") WHERE "agent_sessions"."status_message_global_id" is not null;
