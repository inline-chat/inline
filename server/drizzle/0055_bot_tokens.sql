CREATE TABLE "bot_tokens" (
	"id" serial PRIMARY KEY NOT NULL,
	"bot_user_id" integer NOT NULL,
	"session_id" integer NOT NULL,
	"token_encrypted" "bytea" NOT NULL,
	"token_iv" "bytea" NOT NULL,
	"token_tag" "bytea" NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "bot_tokens" ADD CONSTRAINT "bot_tokens_bot_user_id_users_id_fk" FOREIGN KEY ("bot_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bot_tokens" ADD CONSTRAINT "bot_tokens_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "bot_tokens_bot_user_id_unique" ON "bot_tokens" USING btree ("bot_user_id");