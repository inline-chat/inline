CREATE TABLE "chat_access" (
	"chat_id" integer NOT NULL,
	"user_id" integer NOT NULL,
	CONSTRAINT "chat_access_chat_id_user_id_pk" PRIMARY KEY("chat_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "chat_access_state" (
	"id" smallint PRIMARY KEY DEFAULT 1 NOT NULL,
	"backfilled_at" timestamp (3) with time zone NOT NULL,
	CONSTRAINT "chat_access_state_singleton" CHECK ("chat_access_state"."id" = 1)
);
--> statement-breakpoint
CREATE INDEX "chat_access_user_chat_idx" ON "chat_access" USING btree ("user_id","chat_id");