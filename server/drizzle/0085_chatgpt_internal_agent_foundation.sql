CREATE TABLE "oauth_connections" (
	"id" serial PRIMARY KEY NOT NULL,
	"provider" varchar(64) NOT NULL,
	"scope_type" varchar(16) NOT NULL,
	"user_id" integer,
	"space_id" integer,
	"connected_by_user_id" integer NOT NULL,
	"credential_ciphertext" "bytea" NOT NULL,
	"identity_ciphertext" "bytea",
	"config_ciphertext" "bytea",
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"expires_at" timestamp (3),
	"last_refresh_at" timestamp (3),
	"last_used_at" timestamp (3),
	"revoked_at" timestamp (3),
	"error_at" timestamp (3),
	"error_code" varchar(128),
	"error_message" text,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "oauth_connections_scope_type_check" CHECK ("oauth_connections"."scope_type" in ('user', 'space')),
	CONSTRAINT "oauth_connections_status_check" CHECK ("oauth_connections"."status" in ('active', 'error', 'revoked')),
	CONSTRAINT "oauth_connections_scope_target_check" CHECK ((
        ("oauth_connections"."scope_type" = 'user' and "oauth_connections"."user_id" is not null and "oauth_connections"."space_id" is null)
        or ("oauth_connections"."scope_type" = 'space' and "oauth_connections"."space_id" is not null and "oauth_connections"."user_id" is null)
      ))
);
--> statement-breakpoint
CREATE TABLE "internal_agent_provider_states" (
	"id" serial PRIMARY KEY NOT NULL,
	"run_id" varchar(128) NOT NULL,
	"provider" varchar(64) NOT NULL,
	"issuer" varchar(128),
	"model" varchar(128),
	"response_id" varchar(256),
	"connection_id" integer,
	"output_msg_global_id" bigint,
	"encrypted_state_ciphertext" "bytea" NOT NULL,
	"encrypted_item_count" integer DEFAULT 0 NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "internal_agent_runs" (
	"id" varchar(128) PRIMARY KEY NOT NULL,
	"agent_key" varchar(64) NOT NULL,
	"run_key" varchar(256) NOT NULL,
	"scope_type" varchar(16) NOT NULL,
	"scope_user_id" integer,
	"scope_space_id" integer,
	"actor_user_id" integer NOT NULL,
	"bot_user_id" integer NOT NULL,
	"chat_id" integer NOT NULL,
	"thread_root_msg_id" integer,
	"trigger_msg_global_id" bigint NOT NULL,
	"output_msg_global_id" bigint,
	"connection_id" integer,
	"status" varchar(32) DEFAULT 'pending' NOT NULL,
	"attempt" integer DEFAULT 0 NOT NULL,
	"lease_owner" varchar(128),
	"lease_expires_at" timestamp (3),
	"heartbeat_at" timestamp (3),
	"started_at" timestamp (3),
	"last_edit_at" timestamp (3),
	"completed_at" timestamp (3),
	"error_code" varchar(128),
	"error_message" text,
	"last_visible_text_length" integer DEFAULT 0 NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "internal_agent_runs_scope_type_check" CHECK ("internal_agent_runs"."scope_type" in ('user', 'space')),
	CONSTRAINT "internal_agent_runs_status_check" CHECK ("internal_agent_runs"."status" in (
        'pending',
        'debouncing',
        'running',
        'streaming',
        'waiting_for_tool',
        'succeeded',
        'failed',
        'cancel_requested',
        'canceled',
        'interrupted'
      )),
	CONSTRAINT "internal_agent_runs_scope_target_check" CHECK ((
        ("internal_agent_runs"."scope_type" = 'user' and "internal_agent_runs"."scope_user_id" is not null and "internal_agent_runs"."scope_space_id" is null)
        or ("internal_agent_runs"."scope_type" = 'space' and "internal_agent_runs"."scope_space_id" is not null and "internal_agent_runs"."scope_user_id" is null)
      ))
);
--> statement-breakpoint
ALTER TABLE "oauth_connections" ADD CONSTRAINT "oauth_connections_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_connections" ADD CONSTRAINT "oauth_connections_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_connections" ADD CONSTRAINT "oauth_connections_connected_by_user_id_users_id_fk" FOREIGN KEY ("connected_by_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_provider_states" ADD CONSTRAINT "internal_agent_provider_states_run_id_internal_agent_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."internal_agent_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_provider_states" ADD CONSTRAINT "internal_agent_provider_states_connection_fk" FOREIGN KEY ("connection_id") REFERENCES "public"."oauth_connections"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_provider_states" ADD CONSTRAINT "internal_agent_provider_states_output_msg_fk" FOREIGN KEY ("output_msg_global_id") REFERENCES "public"."messages"("global_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_scope_user_id_users_id_fk" FOREIGN KEY ("scope_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_scope_space_id_spaces_id_fk" FOREIGN KEY ("scope_space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_actor_user_id_users_id_fk" FOREIGN KEY ("actor_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_trigger_msg_global_id_messages_global_id_fk" FOREIGN KEY ("trigger_msg_global_id") REFERENCES "public"."messages"("global_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_output_msg_global_id_messages_global_id_fk" FOREIGN KEY ("output_msg_global_id") REFERENCES "public"."messages"("global_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_connection_id_oauth_connections_id_fk" FOREIGN KEY ("connection_id") REFERENCES "public"."oauth_connections"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "oauth_connections_provider_user_unique" ON "oauth_connections" USING btree ("provider","scope_type","user_id") WHERE "oauth_connections"."status" = 'active';--> statement-breakpoint
CREATE UNIQUE INDEX "oauth_connections_provider_space_unique" ON "oauth_connections" USING btree ("provider","scope_type","space_id") WHERE "oauth_connections"."status" = 'active';--> statement-breakpoint
CREATE INDEX "oauth_connections_connected_by_user_id_idx" ON "oauth_connections" USING btree ("connected_by_user_id");--> statement-breakpoint
CREATE INDEX "oauth_connections_user_id_idx" ON "oauth_connections" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "oauth_connections_space_id_idx" ON "oauth_connections" USING btree ("space_id");--> statement-breakpoint
CREATE INDEX "oauth_connections_status_expires_at_idx" ON "oauth_connections" USING btree ("status","expires_at");--> statement-breakpoint
CREATE INDEX "oauth_connections_provider_status_idx" ON "oauth_connections" USING btree ("provider","status");--> statement-breakpoint
CREATE UNIQUE INDEX "internal_agent_provider_states_run_provider_unique" ON "internal_agent_provider_states" USING btree ("run_id","provider");--> statement-breakpoint
CREATE INDEX "internal_agent_provider_states_run_id_idx" ON "internal_agent_provider_states" USING btree ("run_id");--> statement-breakpoint
CREATE INDEX "internal_agent_provider_states_connection_id_idx" ON "internal_agent_provider_states" USING btree ("connection_id");--> statement-breakpoint
CREATE INDEX "internal_agent_provider_states_output_msg_global_id_idx" ON "internal_agent_provider_states" USING btree ("output_msg_global_id");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_agent_run_key_idx" ON "internal_agent_runs" USING btree ("agent_key","run_key");--> statement-breakpoint
CREATE UNIQUE INDEX "internal_agent_runs_agent_trigger_msg_unique" ON "internal_agent_runs" USING btree ("agent_key","trigger_msg_global_id");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_status_lease_idx" ON "internal_agent_runs" USING btree ("status","lease_expires_at");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_chat_status_idx" ON "internal_agent_runs" USING btree ("chat_id","status");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_actor_user_id_idx" ON "internal_agent_runs" USING btree ("actor_user_id");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_bot_user_id_idx" ON "internal_agent_runs" USING btree ("bot_user_id");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_connection_id_idx" ON "internal_agent_runs" USING btree ("connection_id");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_scope_user_id_idx" ON "internal_agent_runs" USING btree ("scope_user_id");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_scope_space_id_idx" ON "internal_agent_runs" USING btree ("scope_space_id");--> statement-breakpoint
CREATE INDEX "internal_agent_runs_output_msg_global_id_idx" ON "internal_agent_runs" USING btree ("output_msg_global_id");
