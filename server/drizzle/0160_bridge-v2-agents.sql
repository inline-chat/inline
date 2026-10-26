CREATE SEQUENCE "public"."agent_grant_revision" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1;--> statement-breakpoint
CREATE TABLE "agent_grants" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"bot_user_id" integer NOT NULL,
	"subject_user_id" integer NOT NULL,
	"operations" integer NOT NULL,
	"revision" bigint NOT NULL,
	"granted_by" integer,
	"revoked_at" timestamp (3),
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "agent_participations" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"chat_id" integer NOT NULL,
	"bot_user_id" integer NOT NULL,
	"mode" smallint NOT NULL,
	"output_mode" smallint,
	"joined_by" integer,
	"default_session_id" bigint,
	"revision" bigint DEFAULT 1 NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "agent_runtimes" (
	"bot_user_id" integer PRIMARY KEY NOT NULL,
	"provider" smallint NOT NULL,
	"status" smallint NOT NULL,
	"setup_reason" smallint,
	"setup_text" text,
	"setup_min_version" text,
	"machine_label" text,
	"executable_path_encrypted" "bytea",
	"executable_version" text,
	"manifest_hash" text,
	"bridge_version" text,
	"default_output_mode" smallint DEFAULT 0 NOT NULL,
	"last_seen_at" timestamp (3) NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
DROP INDEX "agent_sessions_chat_bot_unique";--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "parent_session_id" bigint;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "relation" smallint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "workspace_label_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "run_state" smallint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "attention_kind" smallint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "attention_user_ids" integer[];--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "held_by" smallint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "state_revision" bigint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "state_encrypted" "bytea";--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD COLUMN "state_updated_at" timestamp (3);--> statement-breakpoint
ALTER TABLE "agent_grants" ADD CONSTRAINT "agent_grants_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_grants" ADD CONSTRAINT "agent_grants_subject_user_id_users_id_fk" FOREIGN KEY ("subject_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_grants" ADD CONSTRAINT "agent_grants_granted_by_users_id_fk" FOREIGN KEY ("granted_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_participations" ADD CONSTRAINT "agent_participations_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_participations" ADD CONSTRAINT "agent_participations_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_participations" ADD CONSTRAINT "agent_participations_joined_by_users_id_fk" FOREIGN KEY ("joined_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_participations" ADD CONSTRAINT "agent_participations_default_session_id_agent_sessions_id_fk" FOREIGN KEY ("default_session_id") REFERENCES "public"."agent_sessions"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_runtimes" ADD CONSTRAINT "agent_runtimes_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "agent_grants_bot_subject_unique" ON "agent_grants" USING btree ("bot_user_id","subject_user_id");--> statement-breakpoint
CREATE INDEX "agent_grants_subject_idx" ON "agent_grants" USING btree ("subject_user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "agent_participations_chat_bot_unique" ON "agent_participations" USING btree ("chat_id","bot_user_id");--> statement-breakpoint
CREATE INDEX "agent_participations_bot_idx" ON "agent_participations" USING btree ("bot_user_id");--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD CONSTRAINT "agent_sessions_parent_session_id_agent_sessions_id_fk" FOREIGN KEY ("parent_session_id") REFERENCES "public"."agent_sessions"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "agent_sessions_chat_bot_idx" ON "agent_sessions" USING btree ("chat_id","bot_user_id","id");--> statement-breakpoint
CREATE INDEX "agent_sessions_active_state_idx" ON "agent_sessions" USING btree ("chat_id") WHERE "agent_sessions"."run_state" not in (0, 1);--> statement-breakpoint
CREATE INDEX "agent_sessions_parent_idx" ON "agent_sessions" USING btree ("parent_session_id") WHERE "agent_sessions"."parent_session_id" is not null;