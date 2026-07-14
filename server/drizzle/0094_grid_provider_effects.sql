CREATE TABLE "grid_provider_effects" (
	"id" serial PRIMARY KEY NOT NULL,
	"kind" varchar(32) NOT NULL,
	"deduplication_key" varchar(128) NOT NULL,
	"room_id" integer NOT NULL,
	"connection_generation" integer NOT NULL,
	"user_id" integer,
	"available_at" timestamp (3) NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"claim_token" varchar(64),
	"claim_expires_at" timestamp (3),
	"last_error" varchar(500),
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "grid_provider_effects_kind_check" CHECK ("grid_provider_effects"."kind" in ('close_connection', 'revoke_participant')),
	CONSTRAINT "grid_provider_effects_connection_generation_check" CHECK ("grid_provider_effects"."connection_generation" >= 0),
	CONSTRAINT "grid_provider_effects_attempts_check" CHECK ("grid_provider_effects"."attempts" >= 0),
	CONSTRAINT "grid_provider_effects_participant_check" CHECK (("grid_provider_effects"."kind" = 'revoke_participant' and "grid_provider_effects"."user_id" is not null) or ("grid_provider_effects"."kind" = 'close_connection' and "grid_provider_effects"."user_id" is null))
);
--> statement-breakpoint
CREATE UNIQUE INDEX "grid_provider_effects_deduplication_key_unique" ON "grid_provider_effects" USING btree ("deduplication_key");--> statement-breakpoint
CREATE INDEX "grid_provider_effects_ready_idx" ON "grid_provider_effects" USING btree ("available_at","claim_expires_at");