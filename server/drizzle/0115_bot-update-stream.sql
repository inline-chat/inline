CREATE TABLE "bot_message_routes" (
	"bot_user_id" integer NOT NULL,
	"chat_id" integer NOT NULL,
	"message_id" integer NOT NULL,
	"activation_reason" varchar(16) NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"expires_at" timestamp (3) NOT NULL
);
--> statement-breakpoint
CREATE TABLE "bot_update_streams" (
	"bot_user_id" integer PRIMARY KEY NOT NULL,
	"next_update_id" bigint NOT NULL,
	"acknowledged_update_id" bigint DEFAULT 0 NOT NULL,
	"allowed_updates" jsonb NOT NULL,
	"message_trigger" varchar(16) DEFAULT 'mentions' NOT NULL,
	"webhook_url" text,
	"webhook_secret_encrypted" "bytea",
	"poll_lease_token" varchar(64),
	"poll_lease_expires_at" timestamp (3),
	"next_attempt_at" timestamp (3),
	"attempt_count" integer DEFAULT 0 NOT NULL,
	"delivery_locked_at" timestamp (3),
	"last_error_at" timestamp (3),
	"last_error_message" text,
	"dropped_update_count" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "bot_updates" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "bot_updates_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"bot_user_id" integer NOT NULL,
	"update_id" bigint NOT NULL,
	"update_type" varchar(32) NOT NULL,
	"payload_encrypted" "bytea" NOT NULL,
	"source_event_id" varchar(160),
	"expires_at" timestamp (3) NOT NULL,
	"created_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "bot_message_routes" ADD CONSTRAINT "bot_message_routes_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bot_update_streams" ADD CONSTRAINT "bot_update_streams_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bot_updates" ADD CONSTRAINT "bot_updates_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "bot_message_routes_identity_unique" ON "bot_message_routes" USING btree ("bot_user_id","chat_id","message_id");--> statement-breakpoint
CREATE INDEX "bot_message_routes_message_idx" ON "bot_message_routes" USING btree ("chat_id","message_id","bot_user_id");--> statement-breakpoint
CREATE INDEX "bot_message_routes_expiry_idx" ON "bot_message_routes" USING btree ("expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "bot_updates_bot_update_id_unique" ON "bot_updates" USING btree ("bot_user_id","update_id");--> statement-breakpoint
CREATE UNIQUE INDEX "bot_updates_bot_source_event_unique" ON "bot_updates" USING btree ("bot_user_id","source_event_id");--> statement-breakpoint
CREATE INDEX "bot_updates_pending_idx" ON "bot_updates" USING btree ("bot_user_id","update_id","expires_at");--> statement-breakpoint
CREATE INDEX "bot_updates_expiry_idx" ON "bot_updates" USING btree ("expires_at");